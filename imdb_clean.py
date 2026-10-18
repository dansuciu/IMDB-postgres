#!/usr/bin/env python3
"""
Reads the raw IMDb dumps in tmp/ (the *.tsv.gz files downloaded by the
Makefile) and writes clean csv files that createSchema.sql can COPY
straight into postgres:

    tmp/name_basics.csv        nconst, name, birthYear, deathYear,
                               primaryProfession, knownForTitles
    tmp/title_basics.csv       tconst, titleType, primaryTitle, originalTitle,
                               isAdult, startYear, endYear, runtimeMinutes, genres
    tmp/title_akas.csv         titleId, ordering, title, region, language,
                               types, attributes, isOriginalTitle
    tmp/title_crew.csv         tconst, directors, writers
    tmp/title_episode.csv      tconst, parentTconst, seasonNumber, episodeNumber
    tmp/title_principals.csv   tconst, ordering, nconst, category, job
    tmp/title_characters.csv   tconst, ordering, character
    tmp/title_ratings.csv      tconst, averageRating, numVotes

The files are standard csv (RFC 4180) with \\N for a missing value, so they
load with `copy ... with (format csv, null '\\N')`.

Why a python pass is needed at all -- the raw IMDb tsv files cannot be fed to
COPY directly:

  * they are tab separated with no quoting, and titles do contain literal
    backslashes and double quotes, which COPY's text format would read as
    escapes;
  * the "numeric" columns are not always numeric.  IMDb regularly ships rows
    such as an isAdult of 2019 or a runtimeMinutes of "Reality-TV" (the
    columns of a few rows are shifted).  Postgres would abort the whole COPY;
    here such a value simply becomes NULL;
  * a handful of rows have the wrong number of columns altogether; they are
    dropped and counted;
  * the multi-valued columns of title.akas (types, attributes) are separated
    by an ascii \\x02 control character, which is painful to handle in SQL;
  * title.principals stores the characters played as a json array, e.g.
    ["The Narrator","Self"].  It is split here into its own file, one row per
    character, which is what the normalized schema wants.

Everything else -- splitting the comma separated lists (genres, professions,
knownForTitles, directors, writers) and building the relational schema -- is
done in SQL, in createSchema.sql.

Just run it (after the Makefile has downloaded the dumps into tmp/):

    python3 imdb_clean.py
"""

import csv
import gzip
import json
import os
import sys

TMP = 'tmp'

NULL = '\\N'          # what postgres COPY reads back as NULL
IMDB_NULL = '\\N'     # what IMDb writes for a missing value
ARRAY_SEP = '\x02'    # IMDb's separator inside the title.akas array columns

# Column types.  'text' is passed through, 'list' is a comma separated list
# (normalized later, in SQL), 'int'/'num'/'bool' are validated here and
# replaced by NULL when IMDb ships something that is not of that type.
DATASETS = [
  ('name.basics', 'name_basics',
   [('nconst',            'text'),
    ('primaryName',       'text'),
    ('birthYear',         'int'),
    ('deathYear',         'int'),
    ('primaryProfession', 'list'),
    ('knownForTitles',    'list')]),

  ('title.basics', 'title_basics',
   [('tconst',         'text'),
    ('titleType',      'text'),
    ('primaryTitle',   'text'),
    ('originalTitle',  'text'),
    ('isAdult',        'bool'),
    ('startYear',      'int'),
    ('endYear',        'int'),
    ('runtimeMinutes', 'int'),
    ('genres',         'list')]),

  ('title.akas', 'title_akas',
   [('titleId',         'text'),
    ('ordering',        'int'),
    ('title',           'text'),
    ('region',          'text'),
    ('language',        'text'),
    ('types',           'list'),
    ('attributes',      'text'),
    ('isOriginalTitle', 'bool')]),

  ('title.crew', 'title_crew',
   [('tconst',    'text'),
    ('directors', 'list'),
    ('writers',   'list')]),

  ('title.episode', 'title_episode',
   [('tconst',        'text'),
    ('parentTconst',  'text'),
    ('seasonNumber',  'int'),
    ('episodeNumber', 'int')]),

  ('title.principals', 'title_principals',
   [('tconst',     'text'),
    ('ordering',   'int'),
    ('nconst',     'text'),
    ('category',   'text'),
    ('job',        'text'),
    ('characters', 'drop')]),     # exploded into tmp/title_characters.csv

  ('title.ratings', 'title_ratings',
   [('tconst',        'text'),
    ('averageRating', 'num'),
    ('numVotes',      'int')]),
]


def clean_text(v):
  # a multi-valued text column (title.akas.attributes) is flattened to '; '
  v = '; '.join(p.strip() for p in v.split(ARRAY_SEP) if p.strip() != '')
  return NULL if v == '' else v


def clean_list(v):
  # a comma separated list; drop the spaces so that SQL can split on ','.
  # title.akas uses \x02 instead of a comma, so accept both separators.
  v = v.replace(ARRAY_SEP, ',')
  v = ','.join(p.strip() for p in v.split(',') if p.strip() != '')
  return NULL if v == '' else v


def clean_int(v):
  v = v.strip()
  try:
    return str(int(v))
  except ValueError:
    return NULL


def clean_num(v):
  v = v.strip()
  try:
    float(v)
  except ValueError:
    return NULL
  return v


def clean_bool(v):
  v = v.strip()
  if v in ('0', 'false', 'False'):
    return 'f'
  if v in ('1', 'true', 'True'):
    return 't'
  return NULL


CLEANERS = {'text': clean_text, 'list': clean_list, 'int': clean_int,
            'num': clean_num, 'bool': clean_bool}


def split_characters(value):
  """
  title.principals stores the characters played as a json array, e.g.
      ["Dr. Richard Kimble"]      ["Self"]      \\N
  Return the list of character names (possibly empty).
  """
  if value == IMDB_NULL or value.strip() == '':
    return []
  try:
    parsed = json.loads(value)
  except (ValueError, TypeError):
    # not valid json (it happens); fall back to the bare text
    return [value.strip('[]" ')] if value.strip('[]" ') else []
  if isinstance(parsed, list):
    return [str(c).strip() for c in parsed if str(c).strip() != '']
  return [str(parsed).strip()] if str(parsed).strip() != '' else []


def convert(source, target, columns):
  """Convert tmp/<source>.tsv.gz into tmp/<target>.csv."""
  inpath = os.path.join(TMP, source + '.tsv.gz')
  outpath = os.path.join(TMP, target + '.csv')
  names = [c for c, _ in columns]
  keep = [i for i, (_, t) in enumerate(columns) if t != 'drop']
  cleaners = [CLEANERS[t] for _, t in columns if t != 'drop']
  ncols = len(columns)

  # title.principals additionally produces the character names
  characters = None
  if source == 'title.principals':
    charpath = os.path.join(TMP, 'title_characters.csv')
    characters = csv.writer(open(charpath, 'w', newline=''),
                            lineterminator='\n')
    nchars = 0

  print('%-18s -> %s' % (inpath, outpath), flush=True)
  rows = bad = 0
  with gzip.open(inpath, 'rt', encoding='utf-8', errors='replace') as f, \
       open(outpath, 'w', newline='') as out:
    writer = csv.writer(out, lineterminator='\n')

    header = f.readline().rstrip('\r\n').split('\t')
    if header != names:
      print('  WARNING: unexpected header in %s\n    expected %s\n    found    %s'
            % (inpath, names, header), file=sys.stderr)

    for line in f:
      raw = line.rstrip('\r\n').split('\t')
      if len(raw) != ncols:
        bad += 1
        continue

      if characters is not None:
        tconst, ordering = raw[0].strip(), clean_int(raw[1])
        if ordering != NULL:
          for name in split_characters(raw[5]):
            characters.writerow([tconst, ordering, name])
            nchars += 1

      # IMDb writes \N for a missing value; normalize it before cleaning
      fields = ['' if v == IMDB_NULL else v for v in raw]

      writer.writerow([c(fields[i]) for c, i in zip(cleaners, keep)])
      rows += 1
      if rows % 10000000 == 0:
        print('  %d rows...' % rows, flush=True)

  print('  %d rows%s' % (rows, ', %d malformed rows dropped' % bad if bad else ''),
        flush=True)
  if characters is not None:
    print('  %d character names -> %s' % (nchars, charpath), flush=True)


def main():
  if not os.path.isdir(TMP):
    sys.exit('no %s directory: run `make` (it downloads the IMDb dumps there)' % TMP)
  for source, target, columns in DATASETS:
    if not os.path.exists(os.path.join(TMP, source + '.tsv.gz')):
      sys.exit('missing %s/%s.tsv.gz: run `make download` first' % (TMP, source))
    convert(source, target, columns)


if __name__ == '__main__':
  main()
