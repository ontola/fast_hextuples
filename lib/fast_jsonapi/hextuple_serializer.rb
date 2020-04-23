# frozen_string_literal: true

module FastJsonapi
  module HextupleSerializer
    extend ActiveSupport::Concern

    included do
      def iri_from_record(record)
        if self.instance_variable_defined?(:@record_id)
          return record_id.call(record) if record_id.is_a?(Proc)
          return record.send(record_id) if record_id
        end
        raise MandatoryField, 'record has no iri' unless record.respond_to?(:iri)

        record.iri
      end

      def value_to_hex(record, predicate, value)
        lang = value.try(:datatype?) ? value.language : ""
        datatype =
          if value.is_a?(RDF::DynamicURI) || value.try(:uri?)
            'http://www.w3.org/1999/02/22-rdf-syntax-ns#namedNode'
          elsif value.try(:node?)
            'http://www.w3.org/1999/02/22-rdf-syntax-ns#blankNode'
          elsif value.try(:datatype?)
            value.datatype
          else
            lit = RDF::Literal(value)
            value = lit.value
            lit.datatype.to_s
          end

        [
          iri_from_record(record).to_s,
          predicate.to_s,
          value,
          datatype,
          lang,
          ''
        ]
      end
    end
  end
end
