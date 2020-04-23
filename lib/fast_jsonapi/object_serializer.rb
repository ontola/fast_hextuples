# frozen_string_literal: true

require 'active_support/time'
require 'active_support/concern'
require 'active_support/inflector'
require 'active_support/core_ext/numeric/time'
require 'fast_jsonapi/helpers'
require 'fast_jsonapi/hextuple_serializer'
require 'fast_jsonapi/attribute'
require 'fast_jsonapi/relationship'
require 'fast_jsonapi/serialization_core'

module FastJsonapi
  module ObjectSerializer
    extend ActiveSupport::Concern
    include SerializationCore

    SERIALIZABLE_HASH_NOTIFICATION = 'render.fast_jsonapi.serializable_hash'
    SERIALIZED_JSON_NOTIFICATION = 'render.fast_jsonapi.serialized_json'
    TRANSFORMS_MAPPING = {
      camel: :camelize,
      camel_lower: [:camelize, :lower],
      dash: :dasherize,
      underscore: :underscore
    }.freeze

    included do
      # Set record_type based on the name of the serializer class
      set_type(reflected_record_type) if reflected_record_type
    end

    def initialize(resource, options = {})
      process_options(options)

      @resource = resource
    end

    def serializable_hextuples
      if is_collection?(@resource, @is_collection)
        hextuples_for_collection
      elsif !@resource
        []
      else
        hextuples_for_one_record
      end
    end

    def hextuples_for_one_record
      serializable_hextuples = []

      serializable_hextuples.concat self.class.record_hextuples(
        @resource,
        @fieldsets[self.class.record_type.to_sym],
        @includes,
        @params
      )

      if @includes.present?
        serializable_hextuples.concat self.class.get_included_records(
          @resource,
          @includes,
          @known_included_objects,
          @fieldsets,
          @params
        )
      end

      serializable_hextuples
    end

    def hextuples_for_collection
      data = []
      fieldset = @fieldsets[self.class.record_type.to_sym]
      @resource.each do |record|
        data.concat self.class.record_hextuples(record, fieldset, @params)
        data.concat self.class.get_included_records(record, @includes, @known_included_objects, @fieldsets, @params) if @includes.present?
      end

      data
    end

    private

    def process_options(options)
      @fieldsets = deep_symbolize(options[:fields].presence || {})
      @params = {}

      return if options.blank?

      @known_included_objects = {}
      @meta = options[:meta]
      @is_collection = options[:is_collection]
      @params = options[:params] || {}
      raise ArgumentError.new("`params` option passed to serializer must be a hash") unless @params.is_a?(Hash)

      if options[:include].present?
        @includes = options[:include].reject(&:blank?).map(&:to_sym)
        self.class.validate_includes!(@includes)
      end
    end

    def deep_symbolize(collection)
      if collection.is_a? Hash
        collection.each_with_object({}) do |(k, v), hsh|
          hsh[k.to_sym] = deep_symbolize(v)
        end
      elsif collection.is_a? Array
        collection.map { |i| deep_symbolize(i) }
      else
        collection.to_sym
      end
    end

    def is_collection?(resource, force_is_collection = nil)
      return force_is_collection unless force_is_collection.nil?

      resource.respond_to?(:each) && !resource.respond_to?(:each_pair)
    end

    class_methods do

      def inherited(subclass)
        super(subclass)
        subclass.attributes_to_serialize = attributes_to_serialize.dup if attributes_to_serialize.present?
        subclass.relationships_to_serialize = relationships_to_serialize.dup if relationships_to_serialize.present?
        subclass.cachable_relationships_to_serialize = cachable_relationships_to_serialize.dup if cachable_relationships_to_serialize.present?
        subclass.uncachable_relationships_to_serialize = uncachable_relationships_to_serialize.dup if uncachable_relationships_to_serialize.present?
        subclass.transform_method = transform_method
        subclass.cache_store_instance = cache_store_instance
        subclass.cache_store_options = cache_store_options
        subclass.set_type(subclass.reflected_record_type) if subclass.reflected_record_type
        subclass.meta_to_serialize = meta_to_serialize
        subclass.record_id = record_id
      end

      def reflected_record_type
        return @reflected_record_type if defined?(@reflected_record_type)

        @reflected_record_type ||= begin
          if self.name && self.name.end_with?('Serializer')
            self.name.split('::').last.chomp('Serializer').underscore.to_sym
          end
        end
      end

      def set_key_transform(transform_name)
        self.transform_method = TRANSFORMS_MAPPING[transform_name.to_sym]

        # ensure that the record type is correctly transformed
        if record_type
          set_type(record_type)
        elsif reflected_record_type
          set_type(reflected_record_type)
        end
      end

      def run_key_transform(input)
        if self.transform_method.present?
          input.to_s.send(*@transform_method).to_sym
        else
          input.to_sym
        end
      end

      def use_hyphen
        warn('DEPRECATION WARNING: use_hyphen is deprecated and will be removed from fast_jsonapi 2.0 use (set_key_transform :dash) instead')
        set_key_transform :dash
      end

      def set_type(type_name)
        self.record_type = run_key_transform(type_name)
      end

      def set_id(id_name = nil, &block)
        self.record_id = block || id_name
      end

      def cache_options(cache_options)
        # FIXME: remove this if block once deprecated cache_options are not supported anymore
        if !cache_options.key?(:store)
          # fall back to old, deprecated behaviour because no store was passed.
          # we assume the user explicitly wants new behaviour if he passed a
          # store because this is the new syntax.
          deprecated_cache_options(cache_options)
          return
        end

        self.cache_store_instance = cache_options[:store]
        self.cache_store_options = cache_options.except(:store)
      end

      # FIXME: remove this method once deprecated cache_options are not supported anymore
      def deprecated_cache_options(cache_options)
        warn('DEPRECATION WARNING: `store:` is a required cache option, we will default to `Rails.cache` for now. See https://github.com/fast-jsonapi/fast_jsonapi#caching for more information.')

        %i[enabled cache_length].select { |key| cache_options.key?(key) }.each do |key|
          warn("DEPRECATION WARNING: `#{key}` is a deprecated cache option and will have no effect soon. See https://github.com/fast-jsonapi/fast_jsonapi#caching for more information.")
        end

        self.cache_store_instance = cache_options[:enabled] ? Rails.cache : nil
        self.cache_store_options = {
          expires_in: cache_options[:cache_length] || 5.minutes,
          race_condition_ttl: cache_options[:race_condition_ttl] || 5.seconds
        }
      end

      def attributes(*attributes_list, &block)
        attributes_list = attributes_list.first if attributes_list.first.class.is_a?(Array)
        options = attributes_list.last.is_a?(Hash) ? attributes_list.pop : {}
        self.attributes_to_serialize = {} if self.attributes_to_serialize.nil?

        # to support calling `attribute` with a lambda, e.g `attribute :key, ->(object) { ... }`
        block = attributes_list.pop if attributes_list.last.is_a?(Proc)

        attributes_list.each do |attr_name|
          method_name = attr_name
          key = run_key_transform(method_name)
          attributes_to_serialize[key] = Attribute.new(
            key: key,
            method: block || method_name,
            options: options
          )
        end
      end

      alias_method :attribute, :attributes

      def add_relationship(relationship)
        self.relationships_to_serialize = {} if relationships_to_serialize.nil?
        self.cachable_relationships_to_serialize = {} if cachable_relationships_to_serialize.nil?
        self.uncachable_relationships_to_serialize = {} if uncachable_relationships_to_serialize.nil?

        if !relationship.cached
          self.uncachable_relationships_to_serialize[relationship.name] = relationship
        else
          self.cachable_relationships_to_serialize[relationship.name] = relationship
        end
        self.relationships_to_serialize[relationship.name] = relationship
      end

      def has_many(relationship_name, options = {}, &block)
        relationship = create_relationship(relationship_name, :has_many, options, block)
        add_relationship(relationship)
      end

      def has_one(relationship_name, options = {}, &block)
        relationship = create_relationship(relationship_name, :has_one, options, block)
        add_relationship(relationship)
      end

      def belongs_to(relationship_name, options = {}, &block)
        relationship = create_relationship(relationship_name, :belongs_to, options, block)
        add_relationship(relationship)
      end

      def meta(meta_name = nil, &block)
        self.meta_to_serialize = block || meta_name
      end

      def create_relationship(base_key, relationship_type, options, block)
        name = base_key.to_sym
        if relationship_type == :has_many
          base_serialization_key = base_key.to_s.singularize
          id_postfix = '_ids'
        else
          base_serialization_key = base_key
          id_postfix = '_id'
        end
        polymorphic = fetch_polymorphic_option(options)

        Relationship.new(
          owner: self,
          key: options[:key] || run_key_transform(base_key),
          name: name,
          predicate: options[:predicate],
          id_method_name: compute_id_method_name(
            options[:id_method_name],
            "#{base_serialization_key}#{id_postfix}".to_sym,
            polymorphic,
            options[:serializer],
            block
          ),
          record_type: options[:record_type],
          object_method_name: options[:object_method_name] || name,
          object_block: block,
          serializer: options[:serializer],
          relationship_type: relationship_type,
          cached: options[:cached],
          polymorphic: polymorphic,
          conditional_proc: options[:if],
          transform_method: @transform_method,
          lazy_load_data: options[:lazy_load_data]
        )
      end

      def compute_id_method_name(custom_iri_method_name, iri_method_name_from_relationship, polymorphic, serializer, block)
        if block.present? || serializer.is_a?(Proc) || polymorphic
          custom_iri_method_name || :iri
        else
          custom_iri_method_name || iri_method_name_from_relationship
        end
      end

      # Checks for the `class_name` property on the Model's association to
      # determine a serializer.
      def association_serializer_for(name)
        model_name = self.name.to_s.demodulize.classify.gsub(/Serializer$/, '')
        model_class_name = model_name

        begin
          model_class = model_class_name.constantize
          return nil unless model_class.respond_to?(:reflect_on_association)

          association_class_name = model_class.reflect_on_association(name).class_name
          return nil unless association_class_name

          "#{association_class_name}Serializer".constantize
        rescue NameError
          raise NameError, "#{self.name} cannot resolve a serializer association for '#{name}'.  " +
            "Attempted to find '#{model_class_name}'. " +
            "Consider specifying the class name directly through `class_name`."
        end
      end

      def serializer_for(name)
        namespace = self.name.gsub(/()?\w+Serializer$/, '')
        serializer_name = name.to_s.demodulize.classify + 'Serializer'
        serializer_class_name = namespace + serializer_name

        begin
          serializer_class_name.constantize
        rescue NameError
          raise NameError, "#{self.name} cannot resolve a serializer class for '#{name}'.  " +
            "Attempted to find '#{serializer_class_name}'. " +
            "Consider specifying the serializer directly through options[:serializer]."
        end
      end

      def fetch_polymorphic_option(options)
        option = options[:polymorphic]
        return false unless option.present?
        return option if option.respond_to? :keys

        {}
      end

      def validate_includes!(includes)
        return if includes.blank?

        includes.each do |include_item|
          klass = self
          parse_include_item(include_item).each do |parsed_include|
            relationships_to_serialize = klass.relationships_to_serialize || {}
            relationship_to_include = relationships_to_serialize[parsed_include]
            # raise ArgumentError, "#{parsed_include} is not specified as a relationship on #{klass.name}" unless relationship_to_include

            # the serializer may change based on the object (e.g. polymorphic relationships),
            # so inner relationships cannot be validated
            break unless relationship_to_include&.static_serializer

            klass = relationship_to_include.static_serializer
          end
        end
      end
    end
  end
end
