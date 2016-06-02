module Bosh::AzureCloud
  class BlobManager
    include Helpers

    MAX_CHUNK_SIZE = 4 * 1024 * 1024  # 4 MB
    HASH_OF_4MB_EMPTY_CONTENT = 'b5cfa9d6c8febd618f91ac2843d50a1c' # The hash value of 4MB empty content

    def initialize(azure_properties, azure_client2)
      @parallel_upload_thread_num = 16
      @parallel_upload_thread_num = azure_properties['parallel_upload_thread_num'].to_i unless azure_properties['parallel_upload_thread_num'].nil?
      @azure_properties = azure_properties
      @azure_client2 = azure_client2

      @logger = Bosh::Clouds::Config.logger
      @blob_client_mutex = Mutex.new
      @storage_accounts_keys = {}
    end

    def delete_blob(storage_account_name, container_name, blob_name)
      @logger.info("delete_blob(#{storage_account_name}, #{container_name}, #{blob_name})")
      initialize_blob_client(storage_account_name) do
        @blob_service_client.delete_blob(container_name, blob_name, {
          :delete_snapshots => :include
        })
      end
    end

    def get_blob_uri(storage_account_name, container_name, blob_name)
      @logger.info("get_blob_uri(#{storage_account_name}, #{container_name}, #{blob_name})")
      initialize_blob_client(storage_account_name) do
        "#{@azure_client.storage_blob_host}/#{container_name}/#{blob_name}"
      end
    end

    def delete_blob_snapshot(storage_account_name, container_name, blob_name, snapshot_time)
      @logger.info("delete_blob_snapshot(#{storage_account_name}, #{container_name}, #{blob_name}, #{snapshot_time})")
      initialize_blob_client(storage_account_name) do
        @blob_service_client.delete_blob(container_name, blob_name, {
          :snapshot => snapshot_time
        })
      end
    end

    def create_page_blob(storage_account_name, container_name, file_path, blob_name)
      @logger.info("create_page_blob(#{storage_account_name}, #{container_name}, #{file_path}, #{blob_name})")
      initialize_blob_client(storage_account_name) do
        begin
          upload_page_blob(container_name, blob_name, file_path, @parallel_upload_thread_num)
        rescue => e
          cloud_error("Failed to upload page blob: #{e.inspect}\n#{e.backtrace.join("\n")}")
        end
      end
    end

    ##
    # Creates an empty vhd blob.
    #
    # @param [String] container_name container name
    # @param [String] blob_name vhd name
    # @param [Integer] blob_size_in_gb blob size in GB
    # @param [Boolean] storage_account_name Is premium or not.
    # @return [void]
    def create_empty_vhd_blob(storage_account_name, container_name, blob_name, blob_size_in_gb)
      @logger.info("create_empty_vhd_blob(#{storage_account_name}, #{container_name}, #{blob_name}, #{blob_size_in_gb})")
      blob_created = false
      initialize_blob_client(storage_account_name) do
        begin
          @logger.info("create_empty_vhd_blob: Start to generate vhd footer")
          opts = {
              :type => :fixed,
              :name => "/tmp/footer.vhd", # Only used to initialize Vhd, no local file is generated.
              :size => blob_size_in_gb
          }
          vhd_footer = Vhd::Library.new(opts).footer.values.join

          # Reference Virtual Hard Disk Image Format Specification
          # http://download.microsoft.com/download/f/f/e/ffef50a5-07dd-4cf8-aaa3-442c0673a029/Virtual%20Hard%20Disk%20Format%20Spec_10_18_06.doc
          vhd_size = blob_size_in_gb * 1024 * 1024 * 1024
          blob_size = vhd_size + 512
          options = {
            :timeout => 120 # seconds
          }
          @logger.info("create_empty_vhd_blob: Create empty vhd blob #{blob_name} with size #{blob_size}")
          @blob_service_client.create_page_blob(container_name, blob_name, blob_size, options)
          blob_created = true

          @logger.info("create_empty_vhd_blob: Start to upload vhd footer")

          @blob_service_client.create_blob_pages(container_name, blob_name, vhd_size, blob_size - 1, vhd_footer, options)
        rescue => e
          @blob_service_client.delete_blob(container_name, blob_name) if blob_created
          cloud_error("Failed to create empty vhd blob: #{e.inspect}\n#{e.backtrace.join("\n")}")
        end
      end
    end

    def get_blob_properties(storage_account_name, container_name, blob_name)
      @logger.info("get_blob_properties(#{storage_account_name}, #{container_name}, #{blob_name})")
      initialize_blob_client(storage_account_name) do
        begin
          blob = @blob_service_client.get_blob_properties(container_name, blob_name)
          blob.properties
        rescue => e
          cloud_error("get_blob_properties: #{e.inspect}\n#{e.backtrace.join("\n")}") unless e.message.include?("(404)")
          nil
        end
      end
    end

    def list_blobs(storage_account_name, container_name, prefix = nil)
      @logger.info("list_blobs(#{storage_account_name}, #{container_name})")
      blobs = Array.new
      initialize_blob_client(storage_account_name) do
        options = {}
        options[:prefix] = prefix unless prefix.nil?
        while true do
          temp = @blob_service_client.list_blobs(container_name, options)
          blobs += temp if temp.size > 0
          break if temp.continuation_token.nil? || temp.continuation_token.empty?
          options[:marker] = temp.continuation_token
        end
      end
      blobs
    end

    def snapshot_blob(storage_account_name, container_name, blob_name, metadata)
      @logger.info("snapshot_blob(#{storage_account_name}, #{container_name}, #{blob_name}, #{metadata})")
      initialize_blob_client(storage_account_name) do
        snapshot_time = @blob_service_client.create_blob_snapshot(container_name, blob_name, {:metadata => metadata})
        @logger.debug("Snapshot time: #{snapshot_time}")
        snapshot_time
      end
    end

    def copy_blob(storage_account_name, container_name, blob_name, source_blob_uri)
      @logger.info("copy_blob(#{storage_account_name}, #{container_name}, #{blob_name}, #{source_blob_uri})")
      initialize_blob_client(storage_account_name) do
        begin
          start_time = Time.new
          extend_blob_service_client = ExtendBlobService.new(@blob_service_client)
          copy_id, copy_status = extend_blob_service_client.copy_blob_from_uri(container_name, blob_name, source_blob_uri)
          @logger.info("Copy id: #{copy_id}, copy status: #{copy_status}")

          copy_status_description = ""
          while copy_status == "pending" do
            blob = @blob_service_client.get_blob_properties(container_name, blob_name)
            blob_props = blob.properties
            if !copy_id.nil? && blob_props[:copy_id] != copy_id
              cloud_error("The progress of copying the blob #{source_blob_uri} to #{container_name}/#{blob_name} was interrupted by other copy operations.")
            end

            copy_status = blob_props[:copy_status]
            copy_status_description = blob_props[:copy_status_description]
            @logger.debug("Copying progress: #{blob_props[:copy_progress]}")

            elapse_time = Time.new - start_time
            copied_bytes, total_bytes = blob_props[:copy_progress].split('/').map { |v| v.to_i }
            interval = copied_bytes == 0 ? 5 : (total_bytes - copied_bytes).to_f / copied_bytes * elapse_time
            interval = 30 if interval > 30
            interval = 1 if interval < 1
            sleep(interval)
          end

          if copy_status == "success"
            duration = Time.new - start_time
            @logger.info("Copy the blob #{source_blob_uri} successfully. Duration: #{duration.inspect}")
          else
            cloud_error("Failed to copy the blob #{source_blob_uri}: \n\tcopy status: #{copy_status}\n\tcopy description: #{copy_status_description}")
          end
        rescue => e
          ignore_exception{
            @blob_service_client.delete_blob(container_name, blob_name)
            @logger.info("Delete the blob #{container_name}/#{blob_name}")
          }
          raise e
        end
      end
    end

    def create_container(storage_account_name, container_name, options = {})
      @logger.info("create_container(#{storage_account_name}, #{container_name}, #{options})")
      initialize_blob_client(storage_account_name) do
        begin
          @blob_service_client.create_container(container_name, options)
          true
        rescue => e
          # Still return true if the container is created by others.
          return true if e.message.include?("(409)")
          cloud_error("Failed to create container: #{e.inspect}\n#{e.backtrace.join("\n")}")
        end
      end
    end

    def has_container?(storage_account_name, container_name)
      @logger.info("has_container?(#{storage_account_name}, #{container_name})")
      initialize_blob_client(storage_account_name) do
        begin
          @blob_service_client.get_container_properties(container_name)
          true
        rescue => e
          cloud_error("has_container?: #{e.inspect}\n#{e.backtrace.join("\n")}") unless e.message.include?("(404)")
          false
        end
      end
    end

    private

    def chunk_size(total_size, chunk_size, offset)
      if offset + chunk_size > total_size
        total_size - offset
      else
        chunk_size
      end
    end

    def compute_chunks(file_path)
      offset = 0
      id = 1
      chunks = []
      file_size = File.lstat(file_path).size
      while offset < file_size
        chunks << Chunk.new(id, file_path, offset, chunk_size(file_size, MAX_CHUNK_SIZE, offset))
        id += 1
        offset += MAX_CHUNK_SIZE
      end
      ChunkList.new(chunks)
    end

    def upload_page_blob_in_threads(file_path, container_name, blob_name, thread_num)
      chunks = compute_chunks(file_path)
      threads = []
      options = {
        :timeout => 120 # seconds
      }
      thread_num.times do |id|
        thread = Thread.new do
          while chunk = chunks.shift
            content = chunk.read
            if Digest::MD5.hexdigest(content) == HASH_OF_4MB_EMPTY_CONTENT
              @logger.debug("upload_page_blob_in_threads: Thread #{id}: Skip empty chunk: #{chunk}")
              next
            end

            retry_count = 0

            begin
              @logger.debug("upload_page_blob_in_threads: Thread #{id}: Uploading chunk: #{chunk}, retry: #{retry_count}")
              @blob_service_client.create_blob_pages(container_name, blob_name, chunk.start_range, chunk.end_range, content, options)
            rescue => e
              @logger.warn("upload_page_blob_in_threads: Thread #{id}: Failed to create_blob_pages, error: #{e.inspect}\n#{e.backtrace.join("\n")}")
              retry_count += 1
              if retry_count > AZURE_MAX_RETRY_COUNT
                # keep other threads from uploading other parts
                chunks.clear!
                raise e
              end
              sleep(10)
              retry
            end
          end
        end
        thread.abort_on_exception = true
        threads << thread
      end
      threads.each { |t| t.join }
    end

    def upload_page_blob(container_name, blob_name, file_path, thread_num)
      @logger.info("upload_page_blob(#{container_name}, #{blob_name}, #{file_path}, #{thread_num})")
      start_time = Time.new
      blob_size = File.lstat(file_path).size
      options = {
        :timeout => 120 # seconds
      }
      @logger.debug("upload_page_blob: create_page_blob(blob_size: #{blob_size}, options: #{options})")
      @blob_service_client.create_page_blob(container_name, blob_name, blob_size, options)
      begin
        upload_page_blob_in_threads(file_path, container_name, blob_name, thread_num)
      rescue => e
        @blob_service_client.delete_blob(container_name, blob_name)
        raise e
      end
      duration = Time.new - start_time
      @logger.info("Duration: #{duration.inspect}")
    end

    def initialize_blob_client(storage_account_name)
      @blob_client_mutex.synchronize do
        unless @storage_accounts_keys.has_key?(storage_account_name)
          storage_account = @azure_client2.get_storage_account_by_name(storage_account_name)
          keys = @azure_client2.get_storage_account_keys_by_name(storage_account_name)
          storage_account[:key] = keys[0]
          @storage_accounts_keys[storage_account_name] = storage_account
        end

        @azure_client = initialize_azure_storage_client(@storage_accounts_keys[storage_account_name], 'blob')
        @blob_service_client = @azure_client.blobs
        yield
      end
    end

  end

  private

  class ChunkList
    def initialize(chunks = [])
      @chunks = chunks
      @mutex = Mutex.new
    end

    def shift
      @mutex.synchronize { @chunks.shift }
    end

    def clear!
      @mutex.synchronize { @chunks.clear }
    end
  end

  class Chunk
    def initialize(id, file_path, offset, chunk_size)
      @id = id
      @file_path = file_path
      @offset = offset
      @chunk_size = chunk_size
    end

    attr_reader :id

    def start_range
      @offset
    end

    def end_range
      @offset + @chunk_size - 1
    end

    def read
      File.open(@file_path, 'rb') do |file|
        file.seek(@offset)
        file.read(@chunk_size)
      end
    end

    def to_s
      "id: #{@id}, offset: #{@offset}, chunk_size: #{@chunk_size}"
    end
  end

  # https://github.com/Azure/azure-sdk-for-ruby/issues/285
  class ExtendBlobService
    def initialize(blob_service_client)
      @blob_service_client = blob_service_client
    end

    def copy_blob_from_uri(destination_container, destination_blob, source_blob_uri, options={})
      query = { }
      query["timeout"] = options[:timeout].to_s if options[:timeout]

      uri = blob_uri(destination_container, destination_blob, query)
      headers = @blob_service_client.service_properties_headers
      headers["x-ms-copy-source"] = source_blob_uri

      response = @blob_service_client.call(:put, uri, nil, headers)
      return response.headers["x-ms-copy-id"], response.headers["x-ms-copy-status"]
    end

    private

    # Generate the URI for a specific Blob.
    #
    # ==== Attributes
    #
    # * +container_name+ - String representing the name of the container.
    # * +blob_name+      - String representing the name of the blob.
    # * +query+          - A Hash of key => value query parameters.
    # * +host+           - The host of the API.
    #
    # Returns a URI.
    def blob_uri(container_name, blob_name, query = {})
      if container_name.nil? || container_name.empty?
        path = blob_name
      else
        path = File.join(container_name, blob_name)
      end

      path = CGI.escape(path.encode('UTF-8'))

      # Unencode the forward slashes to match what the server expects.
      path = path.gsub(/%2F/, '/')
      # Unencode the backward slashes to match what the server expects.
      path = path.gsub(/%5C/, '/')
      # Re-encode the spaces (encoded as space) to the % encoding.
      path = path.gsub(/\+/, '%20')

      @blob_service_client.generate_uri(path, query)
    end
  end
end