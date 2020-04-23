# frozen_string_literal: true

require 'active_support/concern'

module FastJsonapi
  MandatoryField = Class.new(StandardError)

  module SerializationCore
    extend ActiveSupport::Concern

    included do
      class << self
        attr_accessor :attributes_to_serialize,
                      :relationships_to_serialize,
                      :cachable_relationships_to_serialize,
                      :uncachable_relationships_to_serialize,
                      :transform_method,
                      :record_type,
                      :record_id,
                      :cache_store_instance,
                      :cache_store_options,
                      :meta_to_serialize
      end
    end

    class_methods do
      def relationships_hextuples(record, relationships = nil, fieldset = nil, includes_list = [], params = {})
        relationships = relationships_to_serialize if relationships.nil?
        relationships = relationships.slice(*fieldset) if fieldset.present?
        relationships = [] if fieldset == []

        statements = []
        relationships.each do |key, relationship|
          included = includes_list.present? && includes_list.include?(key)
          statements.concat relationship.serialize(record, included, params)
        end

        statements
      end

      def attributes_hextuples(record, fieldset = nil, params = {})
        attributes = attributes_to_serialize
        attributes = attributes.slice(*fieldset) if fieldset.present?
        attributes = {} if fieldset == []

        statements = attributes.flat_map do |k, attr|
          attr.serialize(record, params)
        end

        statements.compact
      end

      def record_hextuples(record, fieldset, includes_list, params = {})
        if cache_store_instance
          record_hex = Rails.cache.fetch(record.cache_key, expires_in: cache_length, race_condition_ttl: race_condition_ttl) do
            temp_hex = []
            temp_hex.concat attributes_hextuples(record, fieldset, params) if attributes_to_serialize.present?
            # temp_hex[:relationships] = relationships_hextuples(record, cachable_relationships_to_serialize, fieldset, includes_list, params) if cachable_relationships_to_serialize.present?
            temp_hex
          end
          # record_hex[:relationships] = record_hex[:relationships].concat(relationships_hextuples(record, uncachable_relationships_to_serialize, fieldset, includes_list, params)) if uncachable_relationships_to_serialize.present?
          record_hex
        else
          record_hex = []
          record_hex.concat attributes_hextuples(record, fieldset, params) if attributes_to_serialize.present?
          record_hex.concat relationships_hextuples(record, nil, fieldset, params) if relationships_to_serialize.present?
          record_hex
        end
      end


      def iri_from_record(record, params)
        return FastJsonapi.call_proc(record_id, record, params) if record_id.is_a?(Proc)
        return record.send(record_id) if record_id
        raise MandatoryField, 'iri is a mandatory field for linked data' unless record.respond_to?(:iri)
        record.iri
      end

      def parse_include_item(include_item)
        return [include_item.to_sym] unless include_item.to_s.include?('.')

        include_item.to_s.split('.').map!(&:to_sym)
      end

      def remaining_items(items)
        return unless items.size > 1

        [items[1..-1].join('.').to_sym]
      end

      # includes handler
      def get_included_records(record, includes_list, known_included_objects, fieldsets, params = {})
        return unless includes_list.present?

        includes_list.sort.each_with_object([]) do |include_item, included_records|
          items = parse_include_item(include_item)
          remaining_items = remaining_items(items)

          items.each do |item|
            next unless relationships_to_serialize && relationships_to_serialize[item]
            relationship_item = relationships_to_serialize[item]
            next unless relationship_item.include_relationship?(record, params)
            relationship_type = relationship_item.relationship_type

            included_objects = relationship_item.fetch_associated_object(record, params)
            next if included_objects.blank?
            included_objects = [included_objects] unless relationship_type == :has_many

            static_serializer = relationship_item.static_serializer
            static_record_type = relationship_item.static_record_type

            included_objects.each do |inc_obj|
              serializer = static_serializer || relationship_item.serializer_for(inc_obj, params)
              record_type = static_record_type || serializer.record_type

              if remaining_items.present?
                serializer_records = serializer.get_included_records(inc_obj, remaining_items, known_included_objects, fieldsets, params)
                included_records.concat(serializer_records) unless serializer_records.empty?
              end

              code = "#{record_type}_#{serializer.iri_from_record(inc_obj, params)}"
              next if known_included_objects.key?(code)

              known_included_objects[code] = inc_obj

              included_records.concat serializer.record_hextuples(inc_obj, fieldsets[record_type], includes_list, params)
            end
          end
        end
      end
    end
  end
end
