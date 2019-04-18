require "uri"
require "http"
require "json"
require "db"
require "sqlite3"
require "option_parser"
require "yaml"

class Provider
  def initialize(server : String,	# API server's base URL
		 prefix : String,	# prefix for query URL
		 suffix : String,	# suffix for query URL
                 image_tag : String,	# JSON tag for image info
		 dbname : String,	# sqlite3 database filename
		 table : String)	# table name for this provider
    # Set up the HTTP client for the API server.  Use this to fetch
    # cover image URLs that aren't in the cache.
    @server = server
    @prefix = prefix
    @suffix = suffix
    @image_tag = image_tag
    uri = URI.parse(@server)
    @client = HTTP::Client.new(uri)

    # Initialize the regular expression used to extract the image
    # URL from the JSON response returned by the API server.
    @regex = /#{@image_tag}\"\s*:\s*\"([^\"]+)\"/

    # Set up the database connection.  Use this to extract
    # URLs from the cache.
    @db = uninitialized DB::Database	# This avoids compiler error
    @db = DB.open dbname
    @dbname = dbname
    @table = table
  end

  def finalize
    if @db
      @db.close
    end
    if @client
      @client.close
    end
  end

  # Try to get a single image URL from the cache database.
  def get_db(isbn : String)
    url = nil
    if @db
      begin
	puts "Attempting to get URL for #{isbn} from #{@dbname}:#{@table}"
	sql = "select url from #{@table} where isbn = ? limit 1"
	puts "Executing #{sql}"
	@db.query sql, isbn do |rs|
	  rs.each do
	    url = rs.read(String)	# FIXME: should save URLs in array
	  end
	end
	if url
	  puts "Got url for #{isbn} from sqlite3 query: #{url}"
	else
	  puts "Unable to find #{isbn} in sqlite3"
	end
      rescue ex
	puts "sqlite3 exception: #{ex.message}"
      end
    end
    return url
  end

  # Add an entry to the cache database
  def add_to_db(isbn : String, url : String)
    puts "Adding db entry for #{isbn} => #{url}"
    sql = "insert into #{@table} values (?, ?)"
    @db.exec sql, isbn, url
  end

  # Try to get a single image URL from the book API provider.
  def get_api(isbn : String)
    url = nil
    if @client
      puts "Attempting to get URL for #{isbn} from #{@server}"
      puts "trying #{@server}"

      # Get JSON and extract thumbnail URL.
      request = @prefix + isbn + @suffix
      puts "Fetching #{@server}#{request}"
      response = @client.get(request)
      if response
	json = response.body
	puts "Response from #{@server}: ", json
	if json =~ @regex
	  url = $1.gsub("zoom=5", "zoom=1").
		   gsub("\\u0026", "&").
		   gsub("&edge=curl", "")
	else
	  puts "Unable to extract image URL from server's response"
	end
      else
	puts "Unable to get book info for #{isbn} from #{@server}"
      end
    end
    return url
  end

  def save_image(url : String, filename : String)
    puts "Fetching image from #{url}"
    jpeg = @client.get(url)
    f = File.open(filename, "wb")
    if f
      f.write(jpeg.body.to_slice)
    else
      puts "Unable to create #{filename}"
    end
    f.close
  end
end

class GoogleBooks < Provider
  def initialize(db : String)
    super("https://books.google.com", "/books?bibkeys=", "&jscmd=viewapi&amp;hl=en",
          "thumbnail_url",
          "sqlite3://#{db}", "gb")
  end
end

class OpenLibrary < Provider
  def initialize(db : String)
    super("https://openlibrary.org", "/api/books?bibkeys=ISBN:", "&jscmd=data&format=json",
          "medium",
          "sqlite3://#{db}", "ol")
  end
end

class Fetcher
  def initialize(provider_names : Array(String), db : String)
    @provider_names = provider_names
    @providers = {} of String => Provider
    @provider_names.each do |name|
      case name
      when "gb"
        @providers[name] = GoogleBooks.new(db)
      when "ol"
        @providers[name] = OpenLibrary.new(db)
      end
    end
  end

  # Get a single URL for a given ISBN.  Try
  # each provider in order and return the first
  # URL found.
  def get_image_url(isbn : String, provider_names : Array(String))
    if provider_names.size == 0
      provider_names = @provider_names
    end
    provider_names.each do |name|
      provider = @providers[name]?
      if provider
	url = provider.get_db(isbn)	# try cache first
	if url
	  return url
	end
	url = provider.get_api(isbn)	# try API server
	if url
	  provider.add_to_db(isbn, url)	# add to cache
	  return url
	end
      end
    end
    return nil
  end

  # Get the JSON representation of the image URLs
  # for an array of ISBNs.
  def get_images_json(isbns : Array(String), provider_names : Array(String))
    urls = {} of String => String
    isbns.each do |isbn|
      url = get_image_url(isbn, provider_names)
      if url
	urls[isbn] = url
      end
    end
    string = JSON.build do |json|
      json.object do
	if urls.size > 0
	  urls.each { |isbn, url| json.field isbn, url }
	else
	  json.field "error", "Bad id parameter"
	end
      end
    end
    puts "JSON response: #{string}"
    return string
  end

end

class Server
  def initialize(port : Int32, provider_names : Array(String), db : String)
    @port = port
    @fetcher = Fetcher.new(provider_names, db)
    @server = uninitialized HTTP::Server
  end

  def get_covers(context : HTTP::Server::Context)
    params = context.request.query_params
    id = params["id"]?
    provider = params["provider"]?
    callback = params["callback"]?
    response = "{}"
    if id
      isbns = id.split(",")
      if provider
	provider_names = provider.split(",")
      else
	provider_names = [] of String
      end
      # FIXME: pass providers list to fetcher.
      json = @fetcher.get_images_json(isbns, provider_names)
      if json
	puts "JSON: #{json}"
	response = json
      else
	puts "Unable to get JSON response for #{id}"
      end
    end
    if callback
      context.response.content_type = "application/javascript"
      context.response.print callback + "(" + response + ")"
    else
      context.response.content_type = "application/json"
      context.response.print response
    end
  end

  def start
    @server = HTTP::Server.new do |context|
      path = context.request.path
      puts "got path #{path}"
      query = context.request.query
      puts "got query #{query}"

      case path
      when "/cover"
        get_covers(context)
      when "/"
        context.response.content_type = "text/plain"
	context.response.print "Welcome to cover"
      else
        context.response.content_type = "text/plain"
	context.response.print "Unrecognized request"
      end
    end

    if @server
      address = @server.bind_tcp "0.0.0.0", @port
      puts "Listening on http://#{address}"
      @server.listen
    end
  end

  def stop
    puts "Server::stop"
    if @server
      @server.close
    end
  end
end

def doit
  banner = <<-BANNER
cover [options] command [IBSN...]
commands:
  test - test fetching of cover URLs
  save - save a cover image
  init - initialize sqlite3 cache
  server - start cover cache server
BANNER

  config_file = "./cover.yml"

  OptionParser.parse! do |parser|
    parser.banner = banner
    parser.on("-c FILENAME", "--config=FILENAME",
              "Specifies the config filename") { |name| config_file = name }
  end

  # Read config file
  puts "Using config file " + config_file
  yaml = File.open(config_file) {|file| YAML.parse(file) }
  port = yaml["port"].as_i
  provider_names = [] of String
  providers = yaml["providers"].as_a.each do |name|
    provider_names << name.as_s
  end
  db = yaml["db"].as_s

  if ARGV.size < 1
    puts banner
    exit 1
  end

  cmd = ARGV[0]
  case cmd
  when "test"
    isbns = ARGV[1, ARGV.size - 1]
    if isbns.size == 0
      puts "Must specify at least one ISBN"
      return
    end
    fetcher = Fetcher.new(provider_names, db)
    json = fetcher.get_images_json(isbns, provider_names)
    if json
      puts "JSON: #{json}"
    else
      puts "Unable to get JSON response for #{isbns}"
    end
  when "server"
    server = Server.new(port, provider_names, db)
    server.start
    server.stop
  else
    puts "Unrecognized command #{cmd}"
  end
end

doit
