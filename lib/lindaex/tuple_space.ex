defmodule LindaEx do
  @moduledoc """
  GenServer implementation of Linda-style tuple spaces.

  Uses an ETS table internally.
  """

  @type space :: :ets.tab
  @type template :: tuple | :ets.match_spec | :'_'

  use GenServer

  @spec start_link(atom) :: GenServer.on_start
  def start_link(name) do
    GenServer.start_link __MODULE__, name, name: name
  end

  @doc """
  If a tuple matching `template` exists in `ts`, return that tuple. If no
  match is found and `mode` is `:block`, block until such a tuple is written
  to the space. If no match is found and `mode` is `:noblock`, return nil.

  Read tuples are _not_ removed from the space.
  """
  @spec read(space, template, :block) :: tuple
  @spec read(space, template, :noblock) :: tuple | nil
  def read(ts, template, mode \\ :block) do
    GenServer.call ts, {:read, translate_template(template), mode}, :infinity
  end

  @doc """
  Return a list of all tuples in `ts` that matches `template`. Return the
  empty list if no tuples match.

  Read tuples are _not_ removed from the space.
  """
  @spec read_all(space, template) :: [tuple]
  def read_all(ts, template) do
    GenServer.call ts, {:read_all, translate_template(template)}
  end

  @doc """
  If a tuple matching `template` exists in `ts`, return that tuple. If no
  match is found and `mode` is `:block`, block until such a tuple is written
  to the space. If no match is found and `mode` is `:noblock`, return nil.

  Taken tuples _are removed_ from the space.
  """
  @spec take(space, template, :block) :: tuple
  @spec take(space, template, :noblock) :: tuple | nil
  def take(ts, template, mode \\ :block) do
    GenServer.call ts, {:take, translate_template(template), mode}, :infinity
  end

  @doc """
  Return a list of all tuples in `ts` that matches `template`. Return an
  empty list if no tuples match.

  Taken tuples _are removed_ from the space.
  """
  @spec take_all(space, template) :: [tuple]
  def take_all(ts, template) do
    GenServer.call ts, {:take_all, translate_template(template)}
  end

  @doc """
  Write a tuple to `ts`. Duplicates and empty tuples are not allowed.
  """
  @spec write(space, tuple) :: :ok
  def write(ts, tuple) do
    GenServer.cast ts, {:write, tuple}
  end

  @doc """
  Update a tuple in the space. `update_op` will be called with the matched
  tuple and is expected to return an updated tuple.
  """
  @spec update(space, template, (tuple -> tuple)) :: :ok
  def update(ts, template, update_op) do
    tuple = take ts, template
    write ts, update_op.(tuple)
  end

  @doc """
  Return the number of tuples in `ts`.
  """
  @spec count(space) :: non_neg_integer
  def count(ts) do
    GenServer.call ts, :count
  end


  defmodule State do
    defstruct space: nil, waiting_read: %{}, waiting_take: %{}

    def add_waiting(state, from = {pid, _ref}, template, action) do
      monitor_ref = Process.monitor pid

      case action do
        :read ->
          %{state | waiting_read: Dict.put(state.waiting_read, monitor_ref, {from, template})}
        :take ->
          %{state | waiting_take: Dict.put(state.waiting_take, monitor_ref, {from, template})}
      end
    end
  end

  def init(name) do
    space = :ets.new name, [:bag]

    {:ok, %State{space: space}}
  end

  def handle_call({:read, template, mode}, from, state) do
    read_or_take :read, template, mode, from, state
  end
 
  def handle_call({:take, template, mode}, from, state) do
    read_or_take :take, template, mode, from, state
  end

  def handle_call({:read_all, template}, _from, state) do
    {:reply, :ets.select(state.space, template), state}
  end

 def handle_call({:take_all, template}, _from, state) do
    tuples = :ets.select state.space, template

    :ets.select_delete state.space, [put_elem(hd(template), 2, [true])]

    {:reply, tuples, state}
  end

  def handle_call(:count, _from, state) do
    {:reply, :ets.info(state.space, :size), state}
  end

  def handle_info({:DOWN, monitor_ref, :process, _pid, _info}, state) do
    waiting_read = Dict.delete state.waiting_read, monitor_ref
    waiting_take = Dict.delete state.waiting_take, monitor_ref

    {:noreply, %{state | waiting_read: waiting_read, waiting_take: waiting_take}}
  end

  defp read_or_take(action, template, mode, from, state) do
    case :ets.select(state.space, template, 1) do
      :"$end_of_table" ->
        case mode do
          :block ->
            {:noreply, State.add_waiting(state, from, template, action)}
          :noblock ->
            {:reply, nil, state}
        end
      {[tuple], _cont} ->
        if action == :take do
          :ets.delete_object state.space, tuple
        end

        {:reply, tuple, state}
    end
  end

  def handle_cast({:write, tuple}, state) do
    {tuple_taken, state} = notify_waiting(state, tuple)

    unless tuple_taken, do: :ets.insert(state.space, tuple)

    {:noreply, state}
  end

  defp notify_waiting(state, tuple) do
    notified_readers = Enum.filter_map state.waiting_read,
      fn({_monitor_ref, {reader, template}}) ->
        case :ets.test_ms(tuple, template) do
          {:ok, false}  ->
            false
          {:ok, _} ->
            GenServer.reply reader, tuple
            true
        end
      end,
      fn({monitor_ref, _}) -> monitor_ref end

    waiting_read = Dict.drop state.waiting_read, notified_readers

    taker = Enum.find state.waiting_take, fn({_monitor_ref, {taker, template}}) ->
      case :ets.test_ms(tuple, template) do
        {:ok, false} ->
          false
        {:ok, _} ->
          GenServer.reply taker, tuple
          true
      end
    end

    waiting_take = case taker do
      {monitor_ref, _} ->
        Process.demonitor monitor_ref, [:flush]
        Dict.delete state.waiting_take, monitor_ref
      nil ->
        state.waiting_take
    end

    {taker, %{state | waiting_read: waiting_read, waiting_take: waiting_take}}
  end

  defp translate_template(:"_"), do: [{:"_", [], [:"$_"]}]

  defp translate_template(match_spec) when is_list(match_spec), do: match_spec

  defp translate_template(template) when is_tuple(template) do
    {template, guards, _} = template
                            |> Tuple.to_list
                            |> Enum.reduce({[], [], 1}, fn(elem, {template, guards, num}) ->
                                 case make_guard(elem, num) do
                                   nil ->
                                     {[elem | template], guards, num}
                                   {var, guard} ->
                                     {[var | template], [guard | guards], num+1}
                                 end
                               end)

    [{List.to_tuple(Enum.reverse(template)), Enum.reverse(guards), [:"$_"]}]
  end

  defp make_guard(elem, num) do
    case atom_to_guard(elem) do
      nil -> 
        nil
      :"==" -> 
        var = :"$#{num}"
        {var, {:"==", var, {:const, elem}}}
      guard -> 
        var = :"$#{num}"
        {var, {guard, var}}
    end
  end

  defp atom_to_guard(:"$atom"), do: :is_atom
  defp atom_to_guard(:"$binary"), do: :is_binary
  defp atom_to_guard(:"$string"), do: :is_binary
  defp atom_to_guard(:"$float"), do: :is_float
  defp atom_to_guard(:"$function"), do: :is_function
  defp atom_to_guard(:"$int"), do: :is_integer
  defp atom_to_guard(:"$integer"), do: :is_integer
  defp atom_to_guard(:"$list"), do: :is_list
  defp atom_to_guard(:"$number"), do: :is_number
  defp atom_to_guard(:"$pid"), do: :is_pid
  defp atom_to_guard(:"$port"), do: :is_port
  defp atom_to_guard(:"$reference"), do: :is_reference
  defp atom_to_guard(:"$tuple"), do: :is_tuple
  defp atom_to_guard(atom) when is_atom(atom) do
    case to_string(atom) =~ ~r/^\$\d+/ do
      true -> :"=="
      false -> nil
    end
  end
  defp atom_to_guard(_), do: nil
end

