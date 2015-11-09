require 'itunes'
require 'feedjira'
require 'typhoeus'
require 'stringio'
require 'mp3info'

def create_request(url, start_byte, end_byte)
  Typhoeus::Request.new(
    url,
    followlocation: true,
    headers: { Range: "bytes=#{start_byte}-#{end_byte}"}
  )
end

def get_feed_url(id)
  itunes = ITunes::Client.new
  podcast = itunes.lookup(id.to_s).results.first
  podcast.feed_url
end

def get_mp3_urls(id)
  feed_url = get_feed_url(id)
  feed = Feedjira::Feed.fetch_and_parse(feed_url)
  mp3_urls = feed.entries.map(&:image)
end

def get_tag_size(res)
  io = StringIO.open(res.body)
  # ver = "#{io.read(3)}.#{io.getbyte}.#{io.getbyte}"
  # puts ver
  io.seek(6)

  # bytes 6-9 encode the tag size
  bytes = io.read(4).bytes

  in_binary = bytes.map do |byte|
    bin = "%08b" % byte # convert to binary showing 8 bits
    bin[1..-1] # get rid of most significant digit
  end

  header_size = 10
  # extended header size is at most 14 bytes
  extended_header_size = 14

  in_binary.join.to_i(2) + header_size + extended_header_size
end

def get_tag_sizes(urls)
  podcasts_metadata = []
  hydra = Typhoeus::Hydra.new

  urls.each do |url|
    request = create_request(url, 0, 9)

    request.on_complete do |response|
      podcasts_metadata << {
        mp3_url: url,
        tag_size: get_tag_size(response)
      }
    end

    hydra.queue(request)
  end

  hydra.run
  podcasts_metadata
end

# gives duration of mp3 in hours
def calculate_duration(mp3, file_size)
  bits = (file_size - mp3.audio_content.first)*8
  kbits = bits/1000
  duration_in_seconds = kbits/mp3.bitrate
  (duration_in_seconds/3600.to_f).round(3)
end

def get_mp3_metadata(id)
  mp3_urls = get_mp3_urls(id)
  podcasts_metadata = get_tag_sizes(mp3_urls)

  hydra = Typhoeus::Hydra.new
  podcasts_metadata.each do |metadata|
    url = metadata[:mp3_url]
    tag_size = metadata[:tag_size]

    request = create_request(url, 0, tag_size)

    request.on_complete do |response|
      begin
        # get the file size in bytes
        file_size = response.headers_hash["Content-Range"][/\/([0-9]+)$/, 1].to_i

        Mp3Info.open(StringIO.open(response.body)) do |mp3|
          metadata[:title]    = mp3.tag.title
          metadata[:year]     = mp3.tag.year
          metadata[:duration] = calculate_duration(mp3, file_size)
        end
      rescue
        puts "couldn't parse tag..."
      end
    end

    hydra.queue(request)
  end

  hydra.run
  podcasts_metadata
end
