
# IMDb in postgres

Install postgres (if you don't have it already), e.g. `brew install postgres`

Install python3 (if you don't have it already), e.g. `brew install python3`

Install wget (if you don't have it already), e.g. `brew install wget`

Then run `make`

**PATIENCE!** it takes about 1h to complete, and needs ~30GB of free disk
(~1.5GB of downloads, ~10GB of csv files in `tmp`, and the database itself)

Optionally, run `make clean` to remove the `tmp` directory

What it does:

* creates the `tmp` directory
* downloads the seven IMDb non-commercial datasets from
  https://datasets.imdbws.com into `tmp`
  (see https://developer.imdb.com/non-commercial-datasets/ for their meaning)
* runs `imdb_clean.py`, which converts them into csv files in `tmp`
* runs `dropdb --if-exists imdb` and `createdb imdb`
* runs `createSchema.sql`, which imports the csv files into a raw staging
  schema, then transforms it into a normalized relational schema
* suggested queries are in `queries.sql`

The individual steps are also available separately:
`make download`, `make convert`, `make load`.

## The schema

IMDb's string ids (`tt0111161`, `nm0000209`) are replaced by integer surrogate
keys, but kept as the `tconst` / `nconst` columns of `Title` and `Person` so
that a row can still be looked up by its IMDb id (or turned into an
`imdb.com/title/<tconst>` URL).

```
Person(personid, nconst, name, birthyear, deathyear)
Title(titleid, tconst, titletype, primarytitle, originaltitle,
      isadult, startyear, endyear, runtimeminutes)

Genre(genreid, genre)                     TitleGenre(titleid, genreid)
Profession(professionid, profession)      PersonProfession(personid, professionid)
KnownFor(personid, titleid)

Aka(titleid, ordering, title, region, language, attributes, isoriginaltitle)
AkaType(titleid, ordering, type)

Episode(titleid, parenttitleid, seasonnumber, episodenumber)
Rating(titleid, averagerating, numvotes)

Directed(titleid, personid)               Wrote(titleid, personid)
Principal(titleid, ordering, personid, category, job)
PrincipalCharacter(titleid, ordering, charactername)
```

The raw dumps are not normalized: `title.basics.genres`,
`name.basics.primaryProfession`, `name.basics.knownForTitles`,
`title.crew.directors` and `title.crew.writers` are comma separated lists
packed into a single column. They are unnested into the many-to-many tables
above by `createSchema.sql`.

## Why there is a python step

The raw IMDb files cannot be fed to postgres' `COPY` as they are, so
`imdb_clean.py` rewrites them as proper csv first:

* they are tab separated with no quoting, and titles do contain literal
  backslashes and double quotes, which `COPY`'s text format would read as
  escapes
* the numeric columns are not always numeric: IMDb regularly ships rows with
  e.g. an `isAdult` of `2019`, or a `runtimeMinutes` of `Reality-TV`, because
  the columns of those rows are shifted. `COPY` would abort on the first one;
  `imdb_clean.py` turns such a value into NULL instead
* a few rows have the wrong number of columns altogether; they are dropped,
  and the count is reported
* the multi-valued `types` and `attributes` columns of `title.akas` are
  separated by an ascii `\x02` control character
* `title.principals` packs the characters played into a json array, e.g.
  `["Michael Corleone"]`. It is split out into `tmp/title_characters.csv`,
  one row per character

Everything else -- unnesting the comma separated lists, assigning the
surrogate keys, building the tables, the keys and the indexes -- is done in
SQL, in `createSchema.sql`.
