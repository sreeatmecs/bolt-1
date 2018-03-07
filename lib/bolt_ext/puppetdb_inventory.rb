#!/usr/bin/env ruby

require 'bolt/puppetdb/config'
require 'json'
require 'httpclient'
require 'optparse'
require 'yaml'

module Bolt
  class PuppetDBInventory
    class Client
      def self.from_config(config)
        uri = if config['server_urls'].is_a? String
                config['server_urls']
              else
                config['server_urls'].first
              end
        uri = URI.parse(uri)
        uri.port ||= 8081

        cacert = File.expand_path(config['cacert'])
        token = config.token

        cert = config['cert']
        key = config['key']

        new(uri, cacert, token: token, cert: cert, key: key)
      end

      def initialize(uri, cacert, token: nil, cert: nil, key: nil)
        @uri = uri
        @cacert = cacert
        @token = token
        @cert = cert
        @key = key
      end

      def query_certnames(query)
        return [] unless query

        body = JSON.generate(query: query)

        response = http_client.post("#{@uri}/pdb/query/v4", body: body, header: headers)
        if response.code != 200
          raise "Failed to query PuppetDB: #{response.body}"
        else
          results = JSON.parse(response.body)
          if results.first && !results.first.key?('certname')
            raise "Query results did not contain a 'certname' field: got #{results.first.keys.join(', ')}"
          end
          results.map { |result| result['certname'] }.uniq
        end
      end

      def http_client
        return @http if @http
        @http = HTTPClient.new
        @http.ssl_config.set_client_cert_file(@cert, @key)
        @http.ssl_config.add_trust_ca(@cacert)

        @http
      end

      def headers
        headers = { 'Content-Type' => 'application/json' }
        headers['X-Authentication'] = @token if @token
        headers
      end
    end

    class CLI
      def initialize(args)
        @args = args
        @cli_opts = {}
        @parser = build_parser
      end

      def build_parser
        parser = OptionParser.new('') do |opts|
          opts.on('--cacert CACERT', "Path to the CA certificate") do |cacert|
            @cli_opts['cacert'] = cacert
          end
          opts.on('--cert CERT', "Path to the certificate") do |cert|
            @cli_opts['cert'] = cert
          end
          opts.on('--key KEY', "Path to the private key") do |key|
            @cli_opts['key'] = key
          end
          opts.on('--token-file TOKEN',
                  "Path to the token file",
                  "Default: #{Bolt::PuppetDB::Config::DEFAULT_TOKEN} if present") do |token|
            @cli_opts['token'] = token
          end
          opts.on('--url URL', "The URL of the PuppetDB server to connect to") do |url|
            @cli_opts['server_urls'] = [url]
          end
          opts.on('--config CONFIG',
                  "The puppetdb.conf file to read configuration from",
                  "Default: #{Bolt::PuppetDB::Config::DEFAULT_CONFIG} if present") do |file|
            @config_file = File.expand_path(file)
          end
          opts.on('--output FILE', '-o FILE',
                  "Where to write the generated inventory file, defaults to stdout") do |file|
            @output_file = file
          end
          opts.on('--trace', "Show stacktraces for exceptions") do |trace|
            @trace = trace
          end
          opts.on('-h', '--help', "Display help") do |_|
            @show_help = true
          end
        end
        parser.banner = <<-BANNER
Usage: bolt-inventory-pdb <input-file> [--output <output-file>] [--url <url>] [auth-options]

Populate the nodes in an inventory file based on PuppetDB queries.

The input file should be a Bolt inventory file, where each 'nodes' entry is
replaced with a 'query' entry to be executed against PuppetDB. The output will
be the input file, with the 'nodes' entry for each group populated with the
query results.

        BANNER
        parser
      end

      def run
        positional_args = @parser.permute(@args)

        if @show_help
          puts @parser.help
          return 0
        end

        inventory_file = positional_args.shift
        unless inventory_file
          raise "Please specify an input file (see --help for details)"
        end

        if positional_args.any?
          raise "Unknown argument(s) #{positional_args.join(', ')}"
        end

        config = Bolt::PuppetDB::Config.new(@config_file, @cli_opts)
        @puppetdb_client = Client.from_config(config)

        unless File.readable?(inventory_file)
          raise "Can't read the inventory file #{inventory_file}"
        end

        inventory = YAML.load_file(inventory_file)
        resolve_group(inventory)

        result = inventory.to_yaml

        if @output_file
          File.write(@output_file, result)
        else
          puts result
        end

        return 0
      rescue StandardError => e
        puts "Error: #{e}"
        puts e.backtrace if @trace
        return 1
      end

      def resolve_group(group)
        group['nodes'] = @puppetdb_client.query_certnames(group['query'])

        group.fetch('groups', []).each do |child|
          resolve_group(child)
        end

        group
      end
    end
  end
end
