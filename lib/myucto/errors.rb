# frozen_string_literal: true
module Myucto
  class Error < StandardError; end
  class Unavailable < Error; end
  class Conflict < Error; end
  class UncertainCreate < Error; end
end
