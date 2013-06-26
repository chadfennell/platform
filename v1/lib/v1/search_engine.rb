require_relative 'config'
require_relative 'schema'
require_relative 'search_engine/river'
require 'tire'

module V1

  module SearchEngine

    ITEMS_JSON_FILE = File.expand_path("../../../spec/items.json", __FILE__)
    COLLECTIONS_JSON_FILE = File.expand_path("../../../spec/collections.json", __FILE__)

    def self.dataset_files
      [
       ITEMS_JSON_FILE,
       COLLECTIONS_JSON_FILE
      ]
    end

    def self.display_indices
      endpoint_config_check
      
      current = alias_to_index(Config.search_index)
      indices.map do |index|
        puts (index == current) ? "#{index}\t(DEPLOYED)" : index
      end      
    end

    def self.indices
      indices = HTTParty.get(Config.search_endpoint + '/_status').parsed_response['indices']
      indices.keys.select {|index| index != '_river'}.sort
    end

    def self.alias_to_index(alias_name)
      alias_object = Tire::Alias.find(alias_name)
      alias_object ? alias_object.index.first : nil
    end

    def self.recreate_env!
      recreate_index!
      import_test_dataset
      create_river
      puts "ElasticSearch docs: #{ doc_count }"
    end

    def self.doc_count
      url = Config.search_endpoint + '/' + Config.search_index + '/' + '_count'
      HTTParty.get(url).parsed_response['count'] rescue 'Error'
    end

    def self.process_input_file(json_file, inject_type)
      # Load and pre-process docs from the json file
      begin        
        docs = JSON.load( File.read(json_file) )
        docs.map {|doc| doc['_type'] = doc['ingestType']} if inject_type
        return docs
      rescue JSON::ParserError => e
        # Try to output roughly 1 test doc so they can see the error.
        raise JSON::ParserError, "JSON parse error: #{e.to_s.split(/\n/).first(25).join("\n")} \n[SNIP]..."
      end
    end

    def self.import_test_dataset
      dataset_files.each {|file| import_data_file file}
    end

    def self.import_data_file(file)
      import_result = nil
      Tire.index(Config.search_index) do |tire|
        import_result = tire.import(process_input_file(file, true))
        tire.refresh
      end

      return display_import_result(import_result)
    end

    def self.update_schema
      endpoint_config_check

      index = Tire.index(Config.search_index)
      schema_mapping.each do |resource, mapping|
        print "Updating schema for '#{resource}': "
        begin
          index.mapping!( resource, mapping )
          puts "OK"
        rescue => e
          puts e.to_s
        end
      end
    end

    def self.schema_mapping
      timestamp = Time.now.to_s
      Schema.full_mapping.each do |res, fields|
        fields['_meta'] = { 'created' => timestamp }
      end
    end

    def self.recreate_index!
      endpoint_config_check
      
      # Delete the river here to avoid it tripping all over itself and getting
      # confused when we create it later
      delete_river
      
      index_name = Config.search_index
      delete_index(index_name)
      sleep 0.5
      create_index(index_name)
    end

    def self.delete_index(name)
      endpoint_config_check
      Tire.index(name).delete
    end
    

    def self.create_index_with_river
      endpoint_config_check

      name = create_index
      River.create_river('index' => name, 'river' => name)
      name
    end
    
    def self.create_index(name=generate_index_name)
      endpoint_config_check

      index = Tire.index(name)
      index.create( 'mappings' => schema_mapping )

      if index.response.code == 200
        puts "Created index '#{name}'"
      else
        raise "Error: #{ JSON.parse(index.response.body)['error'] }" 
      end
      
      name
    end

    def self.generate_index_name
      DateTime.now.strftime('dpla-%Y%m%d-%H%M%S')
    end

    def self.endpoint_config_check
      # Catch any calls that skipped the Tire initializer (perhaps from being run outside of Rails)
      if Tire::Configuration.url != Config.search_endpoint
        raise "It doesn't look like Tire has been initalized to use the correct search endpoint"
      end
    end

    def self.display_import_result(import_result)
      # NOTE: References to 'items' in this method are un-related to the "item" resource
      # that DPLA defines. It's just a coincidence that the names are the same.

      result = JSON.load(import_result.body)
      failures = result['items'].select {|item| !item['index']['error'].nil? }

      if failures.any?
        result_count = result['items'].size
        puts "Imported #{result_count - failures.size}/#{result_count} docs OK"
        puts "\nError: The following docs failed to import correctly:"
        failures.each do |item|
          puts "#{ item['index']['_id'] }: #{ item['index']['error'] }"
        end
      end
      return result['items']
    end

    def self.service_status
      begin
        HTTParty.get(Config.search_endpoint).body
      rescue Exception => e
        "Error: #{e}"
      end
    end

    def self.search_schema
      uri = Config.search_endpoint + '/' + alias_to_index(Config.search_index) + '/_mapping?pretty'
      begin
        HTTParty.get(uri).body
      rescue Exception => e
        "Error: #{e}"
      end
    end

    def self.deploy_index(index)
      raise "Cannot deploy index '#{index}' that doesn't exist, silly." unless Tire.index(index).exists?

      puts "Deploying index '#{index}'"

      # delete named river for this index and default river that's pointing to the currently deployed index
      delete_river(index)
      delete_river
      previous_index = move_alias_to(index)
      create_river
      puts "Index '#{index}' deployed OK."

      if previous_index && previous_index != index
        puts "FYI: Previous index is no longer in use: #{previous_index}"
      end
    end

    def self.move_alias_to(index)
      alias_name = Config.search_index
      current_alias = Tire::Alias.find(alias_name)

      if current_alias.nil?
        puts "Expected alias '#{alias_name}' not found. Creating..."
        result = create_alias(:index => index, :name => alias_name)
        puts "Alias Error: #{result.body}" if result.failure?
        return
      end

      indices = current_alias.indices
      if indices.size > 1
        raise "Surprise! Alias pointing to multiple indices: #{indices.join(', ')}"
      end
      
      previous_index = indices.first
      indices.clear
      indices.add(index)

      current_alias.save
      puts "Updated alias '#{alias_name}' pointing to index '#{index}'"

      previous_index
    end

    def self.create_alias(options)
      Tire::Alias.new(options).save
    end

    def self.recreate_river
      delete_river
      create_river
    end

    def self.create_river
      River.create_river
    end

    def self.delete_river(*args)
      River.delete_river(*args)
    end

  end

end
