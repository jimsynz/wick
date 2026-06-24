defmodule WickTest do
  use ExUnit.Case
  doctest Wick

  test "greets the world" do
    assert Wick.hello() == :world
  end
end
