class DiscourseTheme::Uploader

  THEME_CREATOR_REGEX = /^https:\/\/theme-creator.discourse.org$/i

  def initialize(dir:, api_key:, site:)
    @dir = dir
    @api_key = api_key
    @site = site
    @is_theme_creator = !!(THEME_CREATOR_REGEX =~ site)
    @theme_id = nil
  end

  def compress_dir(gzip, dir)
    sgz = Zlib::GzipWriter.new(File.open(gzip, 'wb'))
    tar = Archive::Tar::Minitar::Output.new(sgz)

    Dir.chdir(dir + "/../") do
      renamed_files = []
      Find.find(File.basename(dir)) do |x|
        basename = File.basename(x)
        Find.prune if basename == "src"
        Find.prune if basename[0] == ?.
        next if File.directory?(x)
        next if basename == "about.json"

        if rename = (basename !~ /\A[\w\-\.\/]+\z/ && x =~ /\/assets\//)
          new_basename = basename.gsub(/[^\w\.\/]/, "-")
          old_name = x.dup
          x = x.gsub(basename, new_basename)
          File.rename(old_name, x)
          regex = /^[^\/]*(?=(\/))\//
          renamed_files << { old: old_name.gsub(regex, ""), new: x.gsub(regex, "") }
        end

        Minitar.pack_file(x, tar)
        File.rename(x, old_name) if rename
      end

      if renamed_files.any?
        json_str = File.read("#{dir}/about.json")
        json = JSON.parse(json_str)

        json["assets"]&.each do |k, v|
          if renamed = renamed_files.find { |hash| hash[:old] == v }
            json["assets"][k] = renamed[:new]
          end
        end

        edit_file("#{dir}/about.json", json.to_json)
      end

      Minitar.pack_file("#{dir.split("/").last}/about.json", tar)
      edit_file("#{dir}/about.json", json_str) if renamed_files.any?
    end
  ensure
    tar.close
    sgz.close
  end

  def edit_file(path, content)
    File.open(path, "w") do |file|
      file.write(content)
      file.close
    end
  end

  def diagnose_errors(json)
    count = 0
    json["theme"]["theme_fields"].each do |row|
      if (error = row["error"]) && error.length > 0
        if count == 0
          puts
        end
        count += 1
        puts
        puts "Error in #{row["target"]} #{row["name"]}: #{row["error"]}"
        puts
      end
    end
    count
  end

  def upload_theme_field(target: , name: , type_id: , value:)

    raise "expecting theme_id to be set!" unless @theme_id

    args = {
      theme: {
        theme_fields: [{
          name: name,
          target: target,
          type_id: type_id,
          value: value
        }]
      }
    }

    endpoint =
      if @is_theme_creator
        "/user_themes/#{@theme_id}"
      else
        "/admin/themes/#{@theme_id}?api_key=#{@api_key}"
      end

    uri = URI.parse(@site + endpoint)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = URI::HTTPS === uri

    request = Net::HTTP::Put.new(uri.request_uri, 'Content-Type' => 'application/json')
    request.body = args.to_json
    add_headers(request)
    http.start do |h|
      response = h.request(request)
      if response.code.to_i == 200
        json = JSON.parse(response.body)
        if diagnose_errors(json) == 0
          puts "(done)"
        end
      else
        puts "Error importing field status: #{response.code}"
      end
    end
  end

  def upload_full_theme
    filename = "#{Pathname.new(Dir.tmpdir).realpath}/bundle_#{SecureRandom.hex}.tar.gz"
    compress_dir(filename, @dir)

    endpoint =
      if @is_theme_creator
        "/user_themes/import.json"
      else
        "/admin/themes/import.json?api_key=#{@api_key}"
      end

    uri = URI.parse(@site + endpoint)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = URI::HTTPS === uri
    File.open(filename) do |tgz|

      request = Net::HTTP::Post::Multipart.new(
        uri.request_uri,
        "bundle" => UploadIO.new(tgz, "application/tar+gzip", "bundle.tar.gz"),
      )
      add_headers(request)
      response = http.request(request)
      if response.code.to_i == 201
        json = JSON.parse(response.body)
        @theme_id = json["theme"]["id"]
        if diagnose_errors(json) == 0
          puts "(done)"
        end
      else
        puts "Error importing theme status: #{response.code}"

        puts response.body
      end
    end

  ensure
    FileUtils.rm_f filename
  end

  private

    def add_headers(request)
      if @is_theme_creator
        request["User-Api-Key"] = @api_key
      end
    end
end
