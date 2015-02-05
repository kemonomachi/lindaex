defmodule LindaExTest do
  use ExUnit.Case

  setup_all do
    test_tuples = [
      {:"Katja-sama", 11, "Seikon no Qwaser", "Ekaterina Kurae"},
      {:Horo, "Ookami to Koushinryou"},
      {:Eclaire, 14, "Dog Days"},
      {:Shiro, 11, "No Game, no Life"}
    ]

    {:ok, test_tuples: test_tuples}
  end

  setup %{test_tuples: test_tuples} do
    LindaEx.take_all :empty, :"_"
    LindaEx.take_all :test, :"_"
    Enum.each test_tuples, &LindaEx.write(:test, &1)

    :ok
  end

  test "tuples are counted correctly", %{test_tuples: test_tuples} do
    assert LindaEx.count(:test) == length(test_tuples)
  end

  test "reading a tuple in the space", %{test_tuples: test_tuples} do
    expected = List.first test_tuples

    assert LindaEx.read(:test, expected, :noblock) === expected
  end

  test "writing a tuple to the space", %{test_tuples: test_tuples} do
    expected = List.first test_tuples

    LindaEx.write :empty, expected

    assert LindaEx.read(:empty, expected, :noblock) === expected
    assert LindaEx.count(:empty) == 1
  end

  test "taking a tuple from the space", %{test_tuples: test_tuples} do
    expected = List.first test_tuples

    LindaEx.write :empty, expected

    assert LindaEx.take(:empty, expected, :noblock) === expected
    assert LindaEx.count(:empty) == 0
  end

  test "wildcard template matches all tuples", %{test_tuples: test_tuples} do
    tuples = LindaEx.read_all :test, :"_"

    assert Enum.sort(tuples) === Enum.sort(test_tuples)
  end

  test "take_all with wildcard template takes all tuples from the space", %{test_tuples: test_tuples} do
    tuples = LindaEx.take_all :test, :"_"

    assert Enum.sort(tuples) === Enum.sort(test_tuples)

    assert LindaEx.count(:test) == 0
  end

  test "tuple matching with types work (non-recursive)" do
    types = [
      {{:"$atom"}, &is_atom/1},
      {{:"$binary"}, &is_binary/1},
      {{:"$string"}, &is_binary/1},
      {{:"$float"}, &is_float/1},
      {{:"$function"}, &is_function/1},
      {{:"$int"}, &is_integer/1},
      {{:"$integer"}, &is_integer/1},
      {{:"$list"}, &is_list/1},
      {{:"$number"}, &is_number/1},
      {{:"$pid"}, &is_pid/1},
      #{{"$port"}, &is_port/1},
      #{{"$reference"}, &is_reference/1},
      {{:"$tuple"}, &is_tuple/1}
    ]

    data = [
      {:atom},
      {<<0, 245, 13>>},
      {"string"},
      {5.3},
      {fn -> nil end},
      {13},
      {2},
      {[]},
      {-1},
      {self},
      {{}}
    ]

    Enum.each data, &LindaEx.write(:empty, &1)

    Enum.each types, fn({type, predicate}) ->
      {item} = LindaEx.take :empty, type

      assert predicate.(item)
    end
  end

  test "tuple matching with wildcards work", %{test_tuples: test_tuples} do
    expected = Enum.filter test_tuples, &(tuple_size(&1) == 3)

    tuples = LindaEx.take_all :test, {:"_", :"_", :"_"}

    assert Enum.sort(tuples) === Enum.sort(expected)
  end

  test "match_spec variables have no special meaning (non-recursive)" do
    expected = {:match_variables, :"$1", :"$13"}

    LindaEx.write :test, expected

    assert LindaEx.take(:test, expected, :noblock) === expected
    assert is_nil(LindaEx.take(:test, expected, :noblock))
  end
end

