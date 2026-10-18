--
-- Example queries over the IMDb database built by createSchema.sql
--
-- Run as:  psql -f queries.sql imdb
--

--------------------------------------------------------------------------------------
-- Queries
--------------------------------------------------------------------------------------

-- the 20 highest rated movies with at least 100,000 votes

select t.primarytitle, t.startyear, r.averagerating, r.numvotes
from Title t, Rating r
where t.titleid = r.titleid and t.titletype = 'movie' and r.numvotes >= 100000
order by r.averagerating desc, r.numvotes desc
limit 20;

-- the 20 actors/actresses with the most movie credits

select p.personid, p.name, count(*) as movies
from Person p, Principal pr, Title t
where p.personid = pr.personid and pr.titleid = t.titleid
  and pr.category in ('actor', 'actress') and t.titletype = 'movie'
group by p.personid, p.name
order by count(*) desc
limit 20;

-- the 20 directors with the highest average rating, over at least 10 movies
-- with at least 10,000 votes each

select p.name, count(*) as movies, round(avg(r.averagerating), 2) as rating
from Person p, Directed d, Title t, Rating r
where p.personid = d.personid and d.titleid = t.titleid and t.titleid = r.titleid
  and t.titletype = 'movie' and r.numvotes >= 10000
group by p.personid, p.name
having count(*) >= 10
order by avg(r.averagerating) desc
limit 20;

-- how many titles of each type are there?

select titletype, count(*)
from Title
group by titletype
order by count(*) desc;

-- the most common genres

select g.genre, count(*)
from Genre g, TitleGenre tg
where g.genreid = tg.genreid
group by g.genre
order by count(*) desc;

-- the number of movies per decade since 1900

select (t.startyear / 10) * 10 as decade, count(*)
from Title t
where t.titletype = 'movie' and t.startyear between 1900 and 2029
group by decade
order by decade;

-- all the movies Tom Hanks acted in, most recent first

select t.primarytitle, t.startyear, pc.charactername
from Person p
     join Principal pr on pr.personid = p.personid
     join Title t on t.titleid = pr.titleid
     left outer join PrincipalCharacter pc
       on pc.titleid = pr.titleid and pc.ordering = pr.ordering
where p.name = 'Tom Hanks' and pr.category in ('actor', 'actress')
  and t.titletype = 'movie'
order by t.startyear desc nulls last;

-- the co-stars of Kevin Bacon: everybody who acted in a movie with him
-- (the "Bacon number 1" set)

select distinct p2.name
from Person p1, Principal pr1, Principal pr2, Person p2
where p1.name = 'Kevin Bacon'
  and p1.personid = pr1.personid
  and pr1.titleid = pr2.titleid
  and pr2.personid = p2.personid
  and p2.personid <> p1.personid
  and pr1.category in ('actor', 'actress')
  and pr2.category in ('actor', 'actress');

-- actor/director pairs who worked together on at least 10 movies

select a.name as actor, d.name as director, count(*) as movies
from Person a, Principal pr, Directed di, Person d, Title t
where a.personid = pr.personid and pr.titleid = t.titleid
  and t.titleid = di.titleid and di.personid = d.personid
  and pr.category in ('actor', 'actress') and t.titletype = 'movie'
  and a.personid <> d.personid
group by a.personid, a.name, d.personid, d.name
having count(*) >= 10
order by count(*) desc
limit 20;

-- the best rated episode of each season of 'Breaking Bad'

select e.seasonnumber, e.episodenumber, t.primarytitle, r.averagerating
from Title series, Episode e, Title t, Rating r
where series.primarytitle = 'Breaking Bad' and series.titletype = 'tvSeries'
  and e.parenttitleid = series.titleid
  and e.titleid = t.titleid and t.titleid = r.titleid
order by e.seasonnumber, e.episodenumber;

-- in how many languages has 'The Godfather' been released?

select count(distinct a.region)
from Title t, Aka a
where t.titleid = a.titleid
  and t.primarytitle = 'The Godfather' and t.titletype = 'movie'
  and t.startyear = 1972;

-- the people with the most professions

select p.name, count(*) as professions, string_agg(pf.profession, ', ')
from Person p, PersonProfession pp, Profession pf
where p.personid = pp.personid and pp.professionid = pf.professionid
group by p.personid, p.name
order by count(*) desc
limit 20;

-- the longest running tv series still listed as running (no end year)

select t.primarytitle, t.startyear, count(distinct e.seasonnumber) as seasons,
       count(*) as episodes
from Title t, Episode e
where t.titleid = e.parenttitleid and t.titletype = 'tvSeries' and t.endyear is null
group by t.titleid, t.primarytitle, t.startyear
order by count(*) desc
limit 20;
