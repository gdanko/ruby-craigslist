require "net/http"
require "json"
require "pp"
require "etc"
require "sqlite3"
require "nokogiri"
require "time"

class Craigslist
	attr_accessor :_success
	attr_accessor :_output
	attr_accessor :_count
	attr_accessor :_errors
	attr_accessor :_debug
	attr_accessor :_urls
	attr_accessor :proxy

	attr_accessor :_db
	attr_accessor :_opts
	attr_accessor :_qs
	attr_accessor :_city
	attr_accessor :_category
	attr_accessor :_href
	attr_accessor :_base
	attr_accessor :_ads

	$optmap = {
		"min" => "minAsk",
		"max" => "maxAsk",
		"query" => "query",
		"s" => "s",
		"haspic" => "hasPic"
	}	

	$valid_qs = [ "s", "min", "max", "query", "sort", "haspic" ]
	$valid_opts = [ "limit" ]
	$homedir = ENV["HOME"]
	$dbfile = "#{$homedir}/.craigslist.db"
	$db = SQLite3::Database.new $dbfile

	def initialize(opts)
		self._db = $db
		self._opts = opts
		self._count = 0
		self._qs = Hash.new
		self._urls = Array.new
		self._ads = Hash.new
		self.setup
		
		if (self._opts["city"])
			self._validate_city(self._opts["city"])
			self._opts.delete("city")
		end

		if (self._opts["category"])
			self._validate_category(self._opts["category"])
			self._opts.delete("category")
		end

		self._validate_opts
	end

	def debug(flag)
		return unless flag
		if (flag == "on")
			self._debug = "on"
		else
			self._debug = "off"
		end
	end

	def _debug_text(text)
		return unless self._debug == "on"
		puts("[Debug] #{text}")
	end		

	def city(*args)
		city = args[0] if args
		if (city)
			self._validate_city(city)
		else
			return self._city || nil 
		end
	end

	def category(*args)
		category = args[0] if args
		if (category)
			self._validate_category(category)
		else
			return self._category || nil
		end
	end

	def query(query)
		if (query)
			self._qs["query"] = query
		else
			return self._qs["query"] || nil
		end
	end

	def sort(sort)
		valid_sort = ["date", "rel"]
		if (sort)
			if (valid_sort.include?(sort))
				self._qs["sort"] = sort
			else
				self._log_text("warn", sprintf("invalid sort option: \"%s\". ignoring.", sort))
			end
		else
			return self._qs["sort"] || nil
		end
	end

	def haspic(haspic)
		valid_haspic = ["yes", "no"]
		if (haspic)
			if (valid_haspic.include?(haspic))
				self._qs["haspic"] = haspic == "yes" ? 1 : 0
			else
				self._log_text("warn", sprintf("invalid haspic option: \"%s\". ignoring.", haspic))
			end
		else
			return self._qs["haspic"] || nil
		end
	end

	def count
		return self._count || 0
	end

	def ads
		return self._ads || nil
	end

	def search()
		qs = Array.new
		self._qs["s"] = 0
		url, content = nil, nil

		if (self._city && self._base && self._href && self._qs["query"])
			# Parse the query string
			self._qs.each do |k,v|
				qs.push(sprintf("%s=%s", $optmap[k], v)) if $valid_qs.include?(k)
			end

			# Construct the URL
			url = sprintf(
				"%s/search/%s?%s",
				self._base,
				self._href,
				qs.join("&")
			)
			self._urls.push(url)

			content = self._fetch_url(url)
			if (content)
				page = Nokogiri::HTML(content)
				self.process_results(page)
			else
				# error
			end
		end
	end

	def process_results(page)
		ads = page.css("p.row")
		# This could be optimized
		ads.each do |ad|
			# pp ad to get the details
			# Ad date
			begin
				date = ad.css("span.pl").children[1].attributes["datetime"].value
				ts = Time.parse(sprintf("%s %s", date.split(/\s+/).first, "00:00:00")).to_i
			rescue
				ts = 0
			end

			# Ad title and link
			begin
				title = ad.css("span.pl").children[3].children[0].text.strip
			rescue
				title = "unknown"
			end

			begin
				href = ad.css("span.pl").children[3].attributes["href"].value
				href = sprintf("%s%s", self._base, href)
			rescue
				href = "unknown"
			end

			# Ad price
			# This is done right
			begin
				price = ad.css("span.price").children.first.text
			rescue
				price = "unknown"
			end

			# Ad has a pic
			begin
				haspic = ad.css("span.px").children[1].children[0].text =~ /pic/ ? 1 : 0
			rescue
				haspic = 0
			end

			# Ad location
			begin
				location = ad.css("span.pnr").children[1].children[0].text.strip
			rescue
				location = "unknown"
			end

			self._ads[ts] = Array.new unless self._ads[ts]

			ad = {
				"date" => date || "NO DATE",
				"url" => href || nil,
				"title" => title || nil,
				"price" => price || nil,
				"location" => location || nil,
				"has_pic" => haspic || 0
			}
			self._ads[ts].push(ad)
		end
		pp self._ads
	end

	def setup()
		select, count, update = nil, nil, nil
		now = Time.now.to_i
		max_seconds = 86400 * 7

		# Does the DB schema exist?
		select = "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name IN ('cities','categories');"
		count = self._db.get_first_value select

		if (count != 2)
			self._log_text("warn", "the database is missing or corrupt - recreating.")
			self._db.execute("DROP TABLE IF EXISTS cities")
			self._db.execute("DROP TABLE IF EXISTS categories")
			self._db.execute("CREATE TABLE cities (country TEXT, city TEXT, subregions TEXT, url TEXT, updated INTEGER)")
			self._db.execute("CREATE TABLE categories (name TEXT, category TEXT, href TEXT, updated INTEGER)")

			self.load_data(db)
		end
	end

	def load_data(db)
		tree, url, content, links = nil, nil, nil, Array.new
		insert, select, row, count, updated = nil, nil, nil, nil, nil
		now = Time.now.to_i

		self._log_text("info", "refreshing the database.")
		# Load countries
		countries = {
			"usa" => "us",
			"canada" => "ca",
			"china" => "cn"
		}

		countries.each do |country,v|
			url = sprintf("http://geo.craigslist.org/iso/%s", v)
			content = self._fetch_url(url)
			if (content)
				page = Nokogiri::HTML(content)
				links = page.css("a")
				links.each do |link|
					city, href = nil, nil
					href = link.attributes["href"].value
					href = href.gsub(/\/$/, "")
					if (href !~ /www\.craigslist\.org/)
						if (href =~ /^http:\/\/([^\.]+)\.craigslist/)
							city = $1
							insert = sprintf(
								"INSERT OR REPLACE INTO cities (country, city, url, updated) VALUES ('%s', '%s', '%s', '%s')",
								country, city, href, now
							)
							db.execute(insert)
						end
					end
				end
			else
				# error
			end
		end

		# Load categories
		categories = {
			"sss" => "forsale",
			"bbb" => "services",
			"ccc" => "community",
			"hhh" => "housing",
			"jjj" => "jobs",
			"ggg" => "gig"
		}

		url = "http://sandiego.craigslist.org/"
		content = self._fetch_url(url)
		if (content)
			page = Nokogiri::HTML(content)
			categories.each_key do |key|
				div = page.css(sprintf("div#%s", key))
				links = div.css("a")
				links.each do |link|
					name = link.children[0].text
					category = categories[key]
					href = link.attributes["data-cat"].value

					# two overrides - damn you, craigslist...
					href = "mca" if name == "motorcycles"
					href = "cta" if name == "cars+trucks";

					if (name != "[ part-time ]")
						insert = db.prepare("INSERT OR REPLACE INTO categories (name, category, href, updated) VALUES (?, ?, ?, ?)")
						insert.execute(name, category, href, now)
					end
				end
			end
		else
			# error
		end
	end

	def _fetch_url(url)
		self._debug_text("Fetching #{url}")
		uri = URI(url)
		http = Net::HTTP.new(uri.host, uri.port)
		http.read_timeout = 10
		req = Net::HTTP::Post.new(uri.request_uri)
		res = http.request(req)
		if (res.code.to_i == 200)
			return res.body
		end
		return nil
	end

	def _validate_city(city)
		if (self._city && self._base)
			current_city = self._city
			current_url = self._base
		end

		select = sprintf(
			"SELECT city,url FROM cities WHERE city = '%s'",
			city
		)
		stm = self._db.prepare select
		rs = stm.execute
		city,url = rs.next

		if (city && url)
			self._city = city
			self._base = url
		else
			if (current_city)
				self._log_text("warn", sprintf("invalid city: \"%s\". reverting to previously selected city.", city))
			else
				self._log_text("fatal", sprintf("invalid city: \"%s\".", city))
			end
		end
	end

	def _validate_category(name)
		if (self._category && self._href)
			current_category = self._category
			current_href = self._href
		end

		select = sprintf(
			"SELECT category,href FROM categories WHERE name ='%s'",
			name
		)
		stm = self._db.prepare select
		rs = stm.execute
		category,href = rs.next

		if (category && href)
			self._category = category
			self._href = href
		else
			if (current_category)
				self._log_text("warn", sprintf("invalid category: \"%s\". reverting to previously selected category.", category))
			else
				self._log_text("fatal", sprintf("invalid category: \"%s\".", category))
			end
		end
	end

	def _log_text(type, text)
		fixed_type = type.downcase.slice(0,1).capitalize + type.slice(1..-1)
		puts("[#{fixed_type}] #{text}")
		exit if type =~ /^fatal$/i
	end

	def _validate_opts
		self._opts.each do |k,v|
			if ($valid_opts.include?k)
				self._qs[k] = v
			else
				self._log_text("warn", sprintf("\"%s\" is an invalid option - ignoring.", k))
			end
		end
		self._opts = nil
	end
end
