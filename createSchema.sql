--
-- IMDb in postgres
--
-- Loads the cleaned csv files produced by imdb_clean.py into a raw,
-- unnormalized staging schema (one table per IMDb dump), then transforms it
-- into a normalized relational schema, then adds keys and indexes.
--
-- Run as:  psql -f createSchema.sql -v filepath=`pwd` imdb
--

--------------------------------------------------------------------------------------
-- 1. Raw schema
--------------------------------------------------------------------------------------

-- One table per IMDb dump (https://developer.imdb.com/non-commercial-datasets/).
-- These are *not* normalized: genres, professions, knownForTitles, directors and
-- writers are comma separated lists packed into a single column.  They are also
-- keyed by the IMDb strings tconst ('tt0000001') and nconst ('nm0000001').

create table name_basics (
  nconst            text,   -- person id, 'nm0000001'
  primaryname       text,
  birthyear         int,
  deathyear         int,
  primaryprofession text,   -- comma separated list
  knownfortitles    text    -- comma separated list of tconst
);

create table title_basics (
  tconst         text,      -- title id, 'tt0000001'
  titletype      text,      -- movie, short, tvSeries, tvEpisode, video, ...
  primarytitle   text,
  originaltitle  text,
  isadult        boolean,
  startyear      int,
  endyear        int,       -- only for tvSeries
  runtimeminutes int,
  genres         text       -- comma separated list, at most three
);

create table title_akas (
  titleid         text,     -- tconst
  ordering        int,      -- (titleid, ordering) is the key
  title           text,
  region          text,
  language        text,
  types           text,     -- comma separated list
  attributes      text,
  isoriginaltitle boolean
);

create table title_crew (
  tconst    text,
  directors text,           -- comma separated list of nconst
  writers   text            -- comma separated list of nconst
);

create table title_episode (
  tconst        text,       -- the episode
  parenttconst  text,       -- the tvSeries it belongs to
  seasonnumber  int,
  episodenumber int
);

create table title_principals (
  tconst   text,
  ordering int,             -- (tconst, ordering) is the key
  nconst   text,
  category text,            -- actor, actress, director, writer, producer, ...
  job      text
);

-- the characters played, extracted by imdb_clean.py from the json array that
-- IMDb packs into the title.principals 'characters' column
create table title_characters (
  tconst        text,
  ordering      int,
  charactername text
);

create table title_ratings (
  tconst        text,
  averagerating numeric(3,1),
  numvotes      int
);

\set name_basics      :filepath '/tmp/name_basics.csv'
\set title_basics     :filepath '/tmp/title_basics.csv'
\set title_akas       :filepath '/tmp/title_akas.csv'
\set title_crew       :filepath '/tmp/title_crew.csv'
\set title_episode    :filepath '/tmp/title_episode.csv'
\set title_principals :filepath '/tmp/title_principals.csv'
\set title_characters :filepath '/tmp/title_characters.csv'
\set title_ratings    :filepath '/tmp/title_ratings.csv'

copy name_basics      from :'name_basics'      with (format csv, null '\N');
copy title_basics     from :'title_basics'     with (format csv, null '\N');
copy title_akas       from :'title_akas'       with (format csv, null '\N');
copy title_crew       from :'title_crew'       with (format csv, null '\N');
copy title_episode    from :'title_episode'    with (format csv, null '\N');
copy title_principals from :'title_principals' with (format csv, null '\N');
copy title_characters from :'title_characters' with (format csv, null '\N');
copy title_ratings    from :'title_ratings'    with (format csv, null '\N');

analyze;

--------------------------------------------------------------------------------------
-- 2. Database design and data transformation
--------------------------------------------------------------------------------------

-- We want the schema below.  Like the DBLP loader, the tables are built with
-- `create table ... as select ...` rather than with insert statements, because
-- inserts are far too slow at this scale.  The keys and foreign keys are added
-- at the end, in section 3.
--
-- The IMDb string ids are replaced by integer surrogate keys (personid,
-- titleid); the original nconst/tconst are kept in Person and Title so that
-- one can still look a row up by its IMDb id, or build an imdb.com URL.
-- Throughout, personid references Person and titleid references Title, and the
-- self-explanatory surrogate keys (personid, titleid, genreid, professionid)
-- are not described again below.
--
--
-- Person(personid, nconst, name, birthyear, deathyear)
--     nconst      the IMDb person id, e.g. 'nm0000158'; the key IMDb itself
--                 uses, and the last part of imdb.com/name/nm0000158
--     name        the full name as IMDb displays it, e.g. 'Tom Hanks'
--     birthyear,  year of birth / of death, as a number; NULL when unknown,
--     deathyear   and deathyear is also NULL for the living
--
-- Title(titleid, tconst, titletype, primarytitle, originaltitle,
--       isadult, startyear, endyear, runtimeminutes)
--     A 'title' is any work: a movie, but also one episode of a tv series, a
--     video game, etc.
--     tconst         the IMDb title id, e.g. 'tt0109830'; the last part of
--                    imdb.com/title/tt0109830
--     titletype      the kind of work; one of movie, short, tvEpisode,
--                    tvMiniSeries, tvMovie, tvPilot, tvSeries, tvShort,
--                    tvSpecial, video, videoGame
--     primarytitle   the title IMDb displays, i.e. the popular or promotional
--                    one, e.g. 'Forrest Gump'
--     originaltitle  the title in the original language of the work; usually
--                    equal to primarytitle, but e.g. primarytitle 'Spirited
--                    Away' vs originaltitle 'Sen to Chihiro no kamikakushi',
--                    or 'Seven' vs 'Se7en'
--     isadult        true for an adult title (about 417k of them)
--     startyear      the release year; for a series, the year it began
--     endyear        only for tvSeries and tvMiniSeries: the year the series
--                    ended; NULL if it is still running (or unknown)
--     runtimeminutes the running time in minutes
--
-- Genre(genreid, genre)
--     genre    one of the 28 IMDb genres, e.g. 'Comedy', 'Film-Noir', 'Sci-Fi'
-- TitleGenre(titleid, genreid)
--     the genres of a title; IMDb assigns at most three, hence a title has
--     between zero and three rows here
--
-- Profession(professionid, profession)
--     profession  one of the 46 IMDb profession names, e.g. 'actor',
--                 'producer', 'camera_department', 'miscellaneous'
-- PersonProfession(personid, professionid)
--     the professions a person is known for (IMDb's primaryProfession); this
--     is a property of the person, independent of any particular title
--
-- KnownFor(personid, titleid)
--     the handful of titles IMDb picks as the ones a person is best known for;
--     it is IMDb's own editorial choice, not derived from the credits, so a
--     person may be 'known for' a title they are not a Principal of
--
-- Aka(titleid, ordering, title, region, language, attributes, isoriginaltitle)
--     The alternative titles of a work: translations, regional releases,
--     working titles, dvd titles, ...
--     ordering         distinguishes the akas of one title; (titleid,
--                      ordering) is the key.  It is just a sequence number
--                      within the title, and carries no meaning of its own
--     title            the alternative title itself
--     region           the ISO 3166-1 alpha-2 country code the alternative is
--                      used in, e.g. 'US', 'DE', 'JP'; NULL when it applies
--                      everywhere
--     language         the ISO 639 language code of this title, e.g. 'de'
--     attributes       free text qualifying the alternative, e.g. 'literal
--                      title', 'transliterated title', 'alternative
--                      spelling'.  Where IMDb gives several, imdb_clean.py has
--                      joined them with '; '
--     isoriginaltitle  true for the row that is the work's original title
-- AkaType(titleid, ordering, type)
--     The kind(s) of each aka; multi-valued, hence its own table.
--     type   one of alternative, dvd, festival, imdbDisplay, original, tv,
--            video, working.  'imdbDisplay' marks the title IMDb shows for
--            that region
--
-- Episode(titleid, parenttitleid, seasonnumber, episodenumber)
--     One row per tvEpisode title, placing it inside its series.
--     titleid        the episode itself (also a row in Title, of titletype
--                    tvEpisode); it is the key, an episode has one position
--     parenttitleid  the tvSeries or tvMiniSeries it belongs to
--     seasonnumber,  its position in the series; both are NULL for an episode
--     episodenumber  IMDb has not placed yet
--
-- Rating(titleid, averagerating, numvotes)
--     Only for titles that have been rated, so far fewer rows than Title.
--     averagerating  the weighted average of the user votes, 1.0 to 10.0
--     numvotes       how many users voted; the useful threshold for ranking,
--                    since a 10.0 from 5 voters means little
--
-- Directed(titleid, personid)
--     who directed a title, and
-- Wrote(titleid, personid)
--     who wrote it.  Both come from IMDb's title.crew, which lists the full
--     set of directors and writers of a title (unlike Principal, which is
--     only the top billed few)
--
-- Principal(titleid, ordering, personid, category, job)
--     The principal cast and crew: the people IMDb lists at the top of a
--     title's page, not the complete credits.
--     ordering   billing order within the title, 1 first; (titleid, ordering)
--                is the key
--     category   the kind of credit; one of actor, actress, archive_footage,
--                archive_sound, casting_director, cinematographer, composer,
--                director, editor, producer, production_designer, self,
--                writer.  'self' is someone appearing as themselves
--     job        the specific job title when IMDb has one, e.g. 'written by',
--                'co-producer', 'director of photography'; finer grained than
--                category, and NULL for most rows (notably for actors)
-- PrincipalCharacter(titleid, ordering, charactername)
--     The character(s) a principal plays in that title; (titleid, ordering)
--     references Principal.  One person can play several characters in one
--     title ('Dr. Strangelove', 'Group Capt. Lionel Mandrake', ...), hence a
--     separate table.
--     charactername  the character as credited, e.g. 'Forrest Gump'


-- Person
create sequence q;
create table Person as
  (select nextval('q') as personid, nb.nconst, nb.primaryname as name,
          nb.birthyear, nb.deathyear
   from name_basics nb);
drop sequence q;
alter table Person add primary key (personid);
alter table Person add unique (nconst);


-- Title
create sequence q;
create table Title as
  (select nextval('q') as titleid, tb.tconst, tb.titletype, tb.primarytitle,
          tb.originaltitle, tb.isadult, tb.startyear, tb.endyear,
          tb.runtimeminutes
   from title_basics tb);
drop sequence q;
alter table Title add primary key (titleid);
alter table Title add unique (tconst);


-- Genre, TitleGenre
-- title_basics.genres is a comma separated list ('Comedy,Drama,Romance');
-- unnest it into its own table and give each genre an id.
create sequence q;
create table Genre as
  (select nextval('q') as genreid, g.genre
   from (select distinct trim(s.genre) as genre
         from title_basics tb
              cross join lateral unnest(string_to_array(tb.genres, ',')) as s(genre)
         where trim(s.genre) <> '') g);
drop sequence q;
alter table Genre add primary key (genreid);
alter table Genre add unique (genre);

create table TitleGenre as
  (select distinct t.titleid, g.genreid
   from title_basics tb
        join Title t on t.tconst = tb.tconst
        cross join lateral unnest(string_to_array(tb.genres, ',')) as s(genre)
        join Genre g on g.genre = trim(s.genre));


-- Profession, PersonProfession
-- same story for name_basics.primaryprofession ('actor,soundtrack,producer')
create sequence q;
create table Profession as
  (select nextval('q') as professionid, p.profession
   from (select distinct trim(s.profession) as profession
         from name_basics nb
              cross join lateral unnest(string_to_array(nb.primaryprofession, ',')) as s(profession)
         where trim(s.profession) <> '') p);
drop sequence q;
alter table Profession add primary key (professionid);
alter table Profession add unique (profession);

create table PersonProfession as
  (select distinct p.personid, pr.professionid
   from name_basics nb
        join Person p on p.nconst = nb.nconst
        cross join lateral unnest(string_to_array(nb.primaryprofession, ',')) as s(profession)
        join Profession pr on pr.profession = trim(s.profession));


-- KnownFor
-- name_basics.knownfortitles is a comma separated list of tconst; the inner
-- join silently drops the few ids that are not in title_basics
create table KnownFor as
  (select distinct p.personid, t.titleid
   from name_basics nb
        join Person p on p.nconst = nb.nconst
        cross join lateral unnest(string_to_array(nb.knownfortitles, ',')) as s(tconst)
        join Title t on t.tconst = trim(s.tconst));


-- Aka: the alternative (regional, translated, working, ...) titles
create table Aka as
  (select t.titleid, ta.ordering, ta.title, ta.region, ta.language,
          ta.attributes, ta.isoriginaltitle
   from title_akas ta
        join Title t on t.tconst = ta.titleid
   where ta.ordering is not null);

-- AkaType: title_akas.types is multi-valued ('imdbDisplay', 'original', ...)
create table AkaType as
  (select distinct t.titleid, ta.ordering, trim(s.type) as type
   from title_akas ta
        join Title t on t.tconst = ta.titleid
        cross join lateral unnest(string_to_array(ta.types, ',')) as s(type)
   where ta.ordering is not null and trim(s.type) <> '');


-- Episode: a tvEpisode title plus its position in its tvSeries
create table Episode as
  (select t.titleid, s.titleid as parenttitleid, te.seasonnumber, te.episodenumber
   from title_episode te
        join Title t on t.tconst = te.tconst
        join Title s on s.tconst = te.parenttconst);


-- Rating
create table Rating as
  (select t.titleid, tr.averagerating, tr.numvotes
   from title_ratings tr
        join Title t on t.tconst = tr.tconst);


-- Directed, Wrote: title_crew packs both as comma separated lists of nconst
create table Directed as
  (select distinct t.titleid, p.personid
   from title_crew tc
        join Title t on t.tconst = tc.tconst
        cross join lateral unnest(string_to_array(tc.directors, ',')) as s(nconst)
        join Person p on p.nconst = trim(s.nconst));

create table Wrote as
  (select distinct t.titleid, p.personid
   from title_crew tc
        join Title t on t.tconst = tc.tconst
        cross join lateral unnest(string_to_array(tc.writers, ',')) as s(nconst)
        join Person p on p.nconst = trim(s.nconst));


-- Principal: the main cast and crew of a title, in billing order
create table Principal as
  (select t.titleid, tp.ordering, p.personid, tp.category, tp.job
   from title_principals tp
        join Title t on t.tconst = tp.tconst
        join Person p on p.nconst = tp.nconst
   where tp.ordering is not null);
alter table Principal add primary key (titleid, ordering);

-- PrincipalCharacter: the character(s) a principal plays in that title
create table PrincipalCharacter as
  (select distinct pr.titleid, pr.ordering, tc.charactername
   from title_characters tc
        join Title t on t.tconst = tc.tconst
        join Principal pr on pr.titleid = t.titleid and pr.ordering = tc.ordering
   where tc.charactername is not null);


--------------------------------------------------------------------------------------
-- 3. Keys, foreign keys and indexes
--------------------------------------------------------------------------------------

alter table TitleGenre         add primary key (titleid, genreid);
alter table PersonProfession   add primary key (personid, professionid);
alter table KnownFor           add primary key (personid, titleid);
alter table Aka                add primary key (titleid, ordering);
alter table AkaType            add primary key (titleid, ordering, type);
alter table Episode            add primary key (titleid);
alter table Rating             add primary key (titleid);
alter table Directed           add primary key (titleid, personid);
alter table Wrote              add primary key (titleid, personid);
-- Principal's primary key was already added above: PrincipalCharacter
-- references it.

alter table TitleGenre         add foreign key (titleid)  references Title;
alter table TitleGenre         add foreign key (genreid)  references Genre;
alter table PersonProfession   add foreign key (personid) references Person;
alter table PersonProfession   add foreign key (professionid) references Profession;
alter table KnownFor           add foreign key (personid) references Person;
alter table KnownFor           add foreign key (titleid)  references Title;
alter table Aka                add foreign key (titleid)  references Title;
alter table AkaType            add foreign key (titleid, ordering) references Aka;
alter table Episode            add foreign key (titleid)  references Title;
alter table Episode            add foreign key (parenttitleid) references Title;
alter table Rating             add foreign key (titleid)  references Title;
alter table Directed           add foreign key (titleid)  references Title;
alter table Directed           add foreign key (personid) references Person;
alter table Wrote              add foreign key (titleid)  references Title;
alter table Wrote              add foreign key (personid) references Person;
alter table Principal          add foreign key (titleid)  references Title;
alter table Principal          add foreign key (personid) references Person;
alter table PrincipalCharacter add foreign key (titleid, ordering) references Principal;

-- indexes for the "other" direction of the many-to-many tables, and for
-- looking a person or a title up by name
create index person_name            on Person(name);
create index title_primarytitle     on Title(primarytitle);
create index title_titletype        on Title(titletype);
create index title_startyear        on Title(startyear);
create index titlegenre_genreid     on TitleGenre(genreid);
create index personprofession_pid   on PersonProfession(professionid);
create index knownfor_titleid       on KnownFor(titleid);
create index aka_title              on Aka(title);
create index episode_parenttitleid  on Episode(parenttitleid);
create index rating_numvotes        on Rating(numvotes);
create index directed_personid      on Directed(personid);
create index wrote_personid         on Wrote(personid);
create index principal_personid     on Principal(personid);
create index principal_category     on Principal(category);
create index princhar_charactername on PrincipalCharacter(charactername);


--------------------------------------------------------------------------------------
-- 4. Drop the raw staging tables
--------------------------------------------------------------------------------------

-- The staging tables hold a second, unnormalized copy of everything (~10GB),
-- so they are dropped.  Comment the following out to keep them around, e.g.
-- to check the transformations above against the raw dumps.

drop table name_basics;
drop table title_basics;
drop table title_akas;
drop table title_crew;
drop table title_episode;
drop table title_principals;
drop table title_characters;
drop table title_ratings;

vacuum analyze;

--------------------------------------------------------------------------------------
-- 5. Queries: see queries.sql
--------------------------------------------------------------------------------------
