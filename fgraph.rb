require 'httparty'
require 'cgi'

module FGraph
  include HTTParty
  base_uri 'https://graph.facebook.com'
  format :json
  
  # Facebook Error
  class FacebookError < StandardError
    attr_reader :data
    
    def initialize(data)
      @data = data
      super("(#{data['type']}) #{data['message']}")
    end
  end
  
  class QueryParseError < FacebookError; end
  class GraphMethodError < FacebookError; end
  class OAuthError < FacebookError; end
  class OAuthAccessTokenError < OAuthError; end
  
  # Collection objects for Graph response with array data.
  #
  class Collection < Array 
    attr_reader :next_url, :previous_url, :next_options, :previous_options
    
    # Initialize Facebook response object with 'data' array value.
    def initialize(response)
      return super unless response
      
      super(response['data'])
      paging = response['paging'] || {}
      self.next_url = paging['next']
      self.previous_url = paging['previous']
    end
    
    def next_url=(url)
      @next_url = url
      @next_options = self.url_options(url)
    end
    
    def previous_url=(url)
      @previous_url = url
      @previous_options = self.url_options(url)
    end
    
    def first?
      @previous_url.blank? and not @next_url.blank?
    end
    
    def next?
      not @next_url.blank?
    end
    
    def previous?
      not @previous_url.blank?
    end
    
    def url_options(url)
      return unless url
      
      uri = URI.parse(url)
      options = {}
      uri.query.split('&').each do |param_set|
         param_set = param_set.split('=')
         options[param_set[0]] = CGI.unescape(param_set[1])
      end
      options
    end
  end
  
  class << self
    attr_accessor :config
    
    # Single object query.
    # 
    def object(id, options={})
      id = self.get_id(id)
      perform_get("/#{id}", options)
    end
  
    # Multiple objects query.
    # 
    def objects(*args)
      options = args.last.is_a?(Hash) ? args.pop : {}
    
      # If first input before option is an array
      if args.length == 1 and args.first.is_a?(Array)
        args = args.first.map do |arg|
          self.get_id(arg)
        end
      end
    
      options = options.merge(:ids => args.join(','))
      perform_get("/", options)
    end
  
    # Returns current user object details.
    # 
    def me(*args)
      options = args.last.is_a?(Hash) ? args.pop : {}
      category = args.shift
    
      path = "me"
      path += "/#{category}" unless category.blank?
      self.object(path, options)
    end
  
    # Request authorization from Facebok to fetch private data in the profile or permission to publish on a
    # user's behalf. Returns Oauth Authorization URL, redirect to this URL to allow user to authorize your
    # application from Facebook.
    #
    def oauth_authorize_url(client_id, redirect_uri, options={})
      self.format_url('/oauth/authorize', {
        :client_id => client_id,
        :redirect_uri => redirect_uri
      }.merge(options))
    end
  
    # Return OAuth access_token. There are two types of access token, user access token and application 
    # access token.
    #
    def oauth_access_token(client_id, client_secret, options={})
      url = self.format_url('/oauth/access_token', {
        :client_id => client_id,
        :client_secret => client_secret
      }.merge(options || {}))
    
      response = self.perform_get(url)
      response_hash = {}
      response.split('&').each do |value|
        value_pair = value.split('=')
        response_hash[value_pair[0]] = value_pair[1]
      end
      response_hash
    end
  
    # Shortcut to retrieve application access token.
    def oauth_app_access_token(client_id, client_secret)
      self.oauth_access_token(client_id, client_secret, :type => 'client_cred')
    end
  
    # Publish to Facebook, you would need to be authorized and provide access token.
    #
    def publish(id, options={})
      id = self.get_id(id)
      self.perform_post("/#{id}", options)
    end
  
    # Delete objects in the graph.
    #
    def remove(id, options={})
      id = self.get_id(id)
      self.perform_delete("/#{id}", options)
    end
  
    # Search over all public objects in the social graph.
    # 
    def search(query, options={})
      self.perform_get("/search", {
        :q => query
      }.merge(options|| {}))
    end
  
    # Download insights data for your application.
    #
    def insights(client_id, app_access_token, options={})
      metric_path = options.delete(:metric_path)
    
      path = "/#{client_id}/insights"
      path += "/#{metric_path}" if metric_path
      
      self.perform_get(path, {
        :access_token => app_access_token
      }.merge(options || {}))
    end
  
    def perform_get(uri, options = {})
      handle_response(get(uri, {:query => options}))
    end
  
    def perform_post(uri, options = {})
      handle_response(post(uri, {:body => options}))
    end
  
    def perform_delete(uri, options = {})
      handle_response(delete(uri, {:body => options}))
    end
  
    def handle_response(response)
      unless response['error']
        return FGraph::Collection.new(response) if response['data']
        response
      else
        case response['error']['type']
          when 'QueryParseException'
            raise QueryParseError, response['error']
          when 'GraphMethodException'
            raise GraphMethodError, response['error']
          when 'OAuthException'
            raise OAuthError, response['error']
          when 'OAuthAccessTokenException'
            raise OAuthAccessTokenError, response['error']
          else
            raise FacebookError, response['error']
        end
      end
    end
  
    def format_url(path, options={})
      url = self.base_uri.dup
      url << path
      unless options.blank?
        url << "?"
      
        option_count = 0
      
        stringified_options = {}
        options.each do |key, value|
          stringified_options[key.to_s] = value
        end
        options = stringified_options
      
        options.each do |option|
          next if option[1].blank?
          url << "&" if option_count > 0
          url << "#{option[0]}=#{CGI.escape(option[1].to_s)}"
          option_count += 1
        end
      end
      url
    end
  
    def method_missing(name, *args, &block)
      names = name.to_s.split('_')
      super unless names.length > 1
    
      case names.shift
        when 'object'
          # object_photos
          self.object("#{args[0]}/#{names[0]}", args[1])
        when 'me'
          # me_photos
          self.me(names[0], args[0])
        when 'publish'
          # publish_feed(id)
          self.publish("#{args[0]}/#{names[0]}", args[1])
        when 'remove'
          # remove_feed(id)
          self.remove("#{args[0]}/#{names[0]}", args[1])
        when 'search'
          # search_user(query)
          options = args[1] || {}
          options[:type] = names[0]
          self.search(args[0], options)
        else
          super
      end
    end
  
    # Return ID['id'] if ID is a hash object
    #
    def get_id(id)
      return unless id
      id = id['id'] || id[:id] if id.is_a?(Hash)
      id
    end
  end
end

module FGraph
  
  # Facebook proxy class to call Facebook Graph API methods with default options.
  # Please refer to FGraph method documentation for more information.
  class Client
    attr_reader :oauth_client, :client_id, :client_secret, :options

    @@instance = nil
    
    # Return static instance of FGraph::Client with default options set in FGraph.config. 
    #
    def self.instance
      return @@instance if @@instance
      if FGraph.config
        @@instance = FGraph::Client.new(
  			 :client_id => FGraph.config['app_id'],
  			 :client_secret => FGraph.config['app_secret']
  		  )
      else
        @@instance = FGraph::Client.new
      end
    end
    
    # Initialize Client with default options, so options are not required to be passed
    # when calling respective Facebook Graph API methods.
    # 
    def initialize(options={})
      @options = options
    end
    
    def update_options(options={})
      @options.merge!(options)
    end
    
    def oauth_authorize_url(redirect_uri, options={})
      FGraph.oauth_authorize_url(self.options[:client_id], redirect_uri, options)
    end
    
    def oauth_access_token(redirect_uri, code)
      FGraph.oauth_access_token(self.options[:client_id], self.options[:client_secret],
        :redirect_uri => redirect_uri, :code => code)
    end
    
    def oauth_app_access_token
      FGraph.oauth_app_access_token(self.options[:client_id], self.options[:client_secret])
    end
    
    def object(id, options={})
      FGraph.object(id, {:access_token => self.options[:access_token]}.merge(options || {}))
    end
    
    def objects(*args)
      options = args.last.is_a?(Hash) ? args.pop : {}
      args << {:access_token => self.options[:access_token]}.merge(options)
      FGraph.objects(*args)
    end
    
    def me(*args)
      options = args.last.is_a?(Hash) ? args.pop : {}
      args << {:access_token => self.options[:access_token]}.merge(options)
      FGraph.me(*args)
    end
    
    def publish(id, options={})
      FGraph.publish(id, {
        :access_token => self.options[:access_token]
      }.merge(options || {}))
    end
    
    def remove(id, options={})
      FGraph.remove(id, {
        :access_token => self.options[:access_token]
      }.merge(options || {}))
      
    end
    
    def search(query, options={})
      FGraph.search(query, options)
    end
    
    def insights(options={})
      unless self.options[:app_access_token]
        self.options[:app_access_token] = self.oauth_app_access_token
      end
      FGraph.insights(self.options[:client_id], self.options[:app_access_token]['access_token'], options)
    end
    
    def method_missing(name, *args, &block)
      names = name.to_s.split('_')
      super unless names.length > 1
    
      case names.shift
        when 'object'
          # object_photos
          self.object("#{args[0]}/#{names[0]}", args[1])
        when 'me'
          # me_photos
          self.me(names[0], args[0])
        when 'publish'
          # publish_feed(id)
          self.publish("#{args[0]}/#{names[0]}", args[1])
        when 'remove'
          # remove_feed(id)
          self.remove("#{args[0]}/#{names[0]}", args[1])
        when 'search'
          # search_user(query)
          options = args[1] || {}
          options[:type] = names[0]
          self.search(args[0], options)
        else
          super
      end
    end
  end
end