# Cover

Cover is a book cover URL cache server for the Koha ILS.  It is a rewrite
in Crystal of [Coce](https://github.com/fredericd/coce), a similar program written in node.js.
It supports reading image URLs from Google Books and OpenLibrary.

Unlike Coce, Cover does NOT support Amazon, because Amazon requires that images be linked to its web site.
I do not believe that is in a library's best interest to support, even in an indirect
way, a malevolent corporation that is attempting to destroy libraries.

## Prerequisites

Cover requires C libraries for yaml and libsqlite3.  These can be installed on Debian
using:

    sudo apt install libyaml-dev
    sudo apt install libsqlite3-dev

## Build

To build Cover, use this:

    shards install
    crystal build src/cover.cr

This will create a binary `cover` in the current directory

## Configuration

Cover keeps its configuration information in a YAML file.  To create
an initial configuration, copy the file `cover.yml.sample` to `cover.yml` and edit as needed.
The configuration file contains these required fields:

* `providers` - a list of providers that you want to use.  The possible values
  are `gb` (Google Books) and `ol` (OpenLibrary).
* `db` - the pathname of the sqlite3 database to be used as a cache.  If the
  database does not exist, Cover will attempt to create it.
* `port` - the number of the port to be used by the Cover server.  The recommended
  value is 8090, to avoid conflict with Coce, which uses 8080.

The configuration file contains these optional fields:

* `sslport` - the number of the port to by used by the Cover server for SSL (https) access.
  The recommended number is 8453, to avoid conflict with Coce, which uses 8443.
* `key` - the pathname of the file containing the SSL key.  For example,
if you obtained your key from Let's Encrypt, the pathname
might be something like `/etc/letsencrypt/live/www.example.com/privkey.pem`.
* `cert` - the pathname of the file containing the SSL certificate.  For example,
if you obtained your certificate from Let's Encrypt, the pathname
might be something like `/etc/letsencrypt/live/www.example.com/fullchain.pem`.
* `log` - the pathname of the log file.  Cover will create the file if it does not
  exist; otherwise, it will append log messages to the end of the file.  If this field
  is not present, Cover will send log messages to stdout.
* `loglevel` - the logging level, corresponding to the values of `Logger::Severity `:
    - debug
    - error
    - fatal
    - info
    - unknown
    - warn

## Running

Cover supports a single option: `--config=FILENAME`, which you can use
to specify to the path to the configuration YAML file.  The default
value is `cover.yml`.

## Test

To test URL fetching without running the server, use this:

    ./cover [config-option] test ISBN...

Cover will print a JSON representation of the cover URLs for the specified
ISBNs, in the same format as it would return to Koha when running as a server.

## Save

To save the cover image for an ISBN to a file, use this:

    ./cover save ISBN filename

If `filename` already exists, it will not be overwritten.

## Server

To run as a server to be used by Koha, use this:

    ./cover [config-option] server

The server will run until terminated by a Control-C or other signal.

### Server testing

In another window, try this command (without the newline)

    curl 'http://localhost:8090/cover?id=1594485356,0451526538,
    0735219869,0891343962&provider=gb'

This should print something like this (with no newlines, and `...` replaced with actual URLs):

    {"1594485356":"https://books.google.com/books/...",
     "0451526538":"https://books.google.com/books/...",
     "0735219869":"https://books.google.com/books/...",
     "0891343962":"https://books.google.com/books/..."}

To include OpenLibrary in the request, add `,ol` to the end of the request URL.

## System Service

It is more convenient to start the Cover server as a system service than to run it
from the command line.  To do this, follow these steps:

* Copy the file `cover.service.sample` to `/etc/systemd/system/cover.service`
  and edit it as necessary.  The values most likely to need editing are `WorkingDirectory`
  and `ExecStart`.
* Run `systemctl daemon-reload` to tell systemd about the new Cover service
* Run `systemctl enable cover` to enable the Cover service
* Run `systemctl start cover` to start the Cover service
* Run `systemctl status cover` to verify that the Cover service is running

## Daily Restart

For some reason, the Cover server stops working after some amount of
time (days, weeks? not sure), apparently after being unable to fetch a
JSON response from Google Books.  The same problem occurred with coce,
but coce would crash instead.  It may be that Google Books limits the
number of covers that can be fetched by a single client in a certain
time period, and refuses to serve any more covers after this limit has
been reached.

In any case, I have not been able to determine the exact source of the
problem, so the workaround is to create a cron job that restarts Cover
on a daily basis.  As root, use the command `crontab -e`, and when the
editor comes up, add the following line to the bottom of the crontab:

    0 5    *   *   *     /bin/systemctl restart cover

This will restart Cover at 5 AM every day.

## Koha configuration

In the Koha system preferences, change the following preferences:

* *Coce*: Enable
* *CoceHost*: If you are using https, set this to `https://KOHAHOST:8453`, where `KOHAHOST` is the actual Koha host name.  Note there is no terminating slash on this URL.
  If you are *not* using https, set this to `http://KOHAHOST:8090`.
* *CoceProviders*: Google Books, Open Library

## Performance

On a ThinkPad X201s (a first-generation Core i7 processor), I ran the command
listed above under "Server testing", in order to get all four of the URLs into the cache.
Then I ran a benchmark on the server using this command (without the newline):

    ab -n 10000 -c 50 'http://localhost:8090/cover?id=1594485356,0451526538,
    0735219869,0891343962&provider=gb'

Here are the results:

```
Document Path:          /cover?id=1594485356,0451526538,0735219869,0891343962&provider=gb
Document Length:        413 bytes

Concurrency Level:      50
Time taken for tests:   2.518 seconds
Complete requests:      10000
Failed requests:        0
Total transferred:      4850000 bytes
HTML transferred:       4130000 bytes
Requests per second:    3971.93 [#/sec] (mean)
Time per request:       12.588 [ms] (mean)
Time per request:       0.252 [ms] (mean, across all concurrent requests)
Transfer rate:          1881.24 [Kbytes/sec] received

Connection Times (ms)
              min  mean[+/-sd] median   max
Connect:        0    0   0.2      0       4
Processing:     1   12   1.5     12      20
Waiting:        1   12   1.5     12      20
Total:          5   13   1.5     12      21

Percentage of the requests served within a certain time (ms)
  50%     12
  66%     12
  75%     12
  80%     13
  90%     15
  95%     16
  98%     17
  99%     19
 100%     21 (longest request)
```
