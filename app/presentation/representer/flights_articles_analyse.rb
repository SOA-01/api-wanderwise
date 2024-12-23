# frozen_string_literal: true

require 'roar/decorator'
require 'roar/json'

require_relative 'article_list'
require_relative 'flights_list'
require_relative 'misc_data'

module WanderWise
  module Representer
    # Represents the Flights and Articles Analyse
    class FlightsArticlesAnalyse < Roar::Decorator
      include Roar::JSON

      property :misc_data, extend: Representer::MiscData, class: OpenStruct
      property :flights, extend: Representer::Flights, class: OpenStruct
      property :articles, extend: Representer::Articles, class: OpenStruct
    end
  end
end
