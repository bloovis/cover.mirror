# Cover

Cover is a book cover URL cache server for the Koha ILS.  It is a rewrite
in Crystal of [Coce](https://github.com/fredericd/coce), a similar program written in node.js.
It supports reading image URLs from Google Books and OpenLibrary.

Unlike Coce, Cover does NOT support Amazon, because Amazon requires that images be linked to its web site.
I do not believe that is in a library's best interest to support, even in an indirect
way, a malevolent corporation that is attempting to destroy libraries.

## Build

To build Cover, use this:

    crystal build src/cover.cr

This will create a binary `cover` in the current directory

## Configuration

Cover keeps its configuration information in a YAML file.  To create
an initial configuration, copy the file `cover.yml.sample` to `cover.yml` and edit as needed.
The configuration file contains these fields:

* `providers` - a list of providers that you want to use.  The possible values
  are `gb` (Google Books) and `ol` (OpenLibrary).
* `db` - the pathname of the sqlite3 database to be used as a cache.  If the
  database does not exist, Cover will attempt to create it.
* `port` - the number of the port to be used by the Cover server.  The recommended
  value is 8090, to avoid conflict with Coce, which uses 8080.

## Running

Cover supports a single option: `--config=FILENAME`, which you can use
to specify to the path to the configuration YAML file.  The default
value is `cover.yml`.

## Test

To test URL fetching without running the server, use this:

    ./cover [config-option] test ISBN...

Cover will print a JSON representation of the cover URLs for the specified
ISBNs, in the same format as it would return to Koha when running as a server.

## Server

To run as a server to be used by Koha, use this:

    ./cover [config-option] server

The server will run until terminated by a Control-C or other signal.
