## dependencies: wget, python3, postgres
## brew install wget
## brew install python3
## brew install postgres

BASEURL  = https://datasets.imdbws.com
DATASETS = name.basics title.akas title.basics title.crew title.episode title.principals title.ratings

all:
	make clean
	make download
	make convert
	make load

## download the raw IMDb dumps (~1.5GB of .tsv.gz) into tmp
download:
	mkdir -p tmp
	@for f in $(DATASETS); do wget -P tmp $(BASEURL)/$$f.tsv.gz; done

## convert them into csv files that postgres can COPY (writes tmp/*.csv)
convert:
	python3 imdb_clean.py

## (re)create the imdb database and import the csv files
load:
	dropdb --if-exists imdb
	createdb imdb
	psql -v ON_ERROR_STOP=1 -f createSchema.sql -v filepath=`pwd` imdb

clean:
	rm -rf tmp

.PHONY: all download convert load clean
