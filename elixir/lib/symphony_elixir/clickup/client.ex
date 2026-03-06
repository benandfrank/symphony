defmodule SymphonyElixir.ClickUp.Client do
  @moduledoc """
  ClickUp REST API client for polling candidate tasks and performing writes.
  """

  require Logger
  alias SymphonyElixir.{Config, Issue}

  @max_parallel_fetches 5
  @connect_timeout_ms 30_000

  # -- Public API --

  @spec fetch_candidate_issues(keyword()) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues(opts \\ []) do
    with {:ok, _token} <- require_token(),
         {:ok, list_id} <- require_list_id() do
      statuses = Config.tracker_active_states()
      do_fetch_by_list(list_id, statuses, opts)
    end
  end

  @spec fetch_issues_by_states([String.t()], keyword()) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names, opts \\ []) when is_list(state_names) do
    normalized = state_names |> Enum.map(&to_string/1) |> Enum.uniq()

    if normalized == [] do
      {:ok, []}
    else
      with {:ok, _token} <- require_token(),
           {:ok, list_id} <- require_list_id() do
        do_fetch_by_list(list_id, normalized, opts)
      end
    end
  end

  @spec fetch_issue_states_by_ids([String.t()], keyword()) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(task_ids, opts \\ []) when is_list(task_ids) do
    ids = Enum.uniq(task_ids)

    if ids == [] do
      {:ok, []}
    else
      with {:ok, _token} <- require_token() do
        do_fetch_by_ids(ids, opts)
      end
    end
  end

  @spec rest(String.t(), String.t(), map() | nil, keyword()) :: {:ok, map()} | {:error, term()}
  def rest(method, path, body \\ nil, opts \\ []) do
    with {:ok, headers} <- auth_headers() do
      url = Config.tracker_endpoint() |> String.trim_trailing("/")
      full_url = url <> path
      request_fun = Keyword.get(opts, :request_fun, &default_request/4)

      case request_fun.(method_atom(method), full_url, headers, body) do
        {:ok, %{status: status, body: resp_body}} when status in 200..299 ->
          {:ok, resp_body}

        {:ok, %{status: status}} ->
          {:error, {:clickup_api_status, status}}

        {:error, reason} ->
          {:error, {:clickup_api_request, reason}}
      end
    end
  end

  @doc false
  @spec normalize_task(map()) :: Issue.t()
  def normalize_task(task) when is_map(task) do
    normalize_task(task, Map.get(task, "dependencies", []))
  end

  # -- Private --

  defp do_fetch_by_list(list_id, statuses, opts) do
    do_fetch_by_list_page(list_id, statuses, opts, 0, [])
  end

  defp do_fetch_by_list_page(list_id, statuses, opts, page, acc) do
    request_fun = Keyword.get(opts, :request_fun, &default_request/4)

    with {:ok, headers} <- auth_headers(),
         {:ok, resp} <- do_list_request(request_fun, list_id, statuses, headers, page) do
      handle_list_response(resp, list_id, statuses, opts, page, acc)
    end
  end

  defp do_list_request(request_fun, list_id, statuses, headers, page) do
    url = build_list_url(list_id, statuses, page)

    case request_fun.(:get, url, headers, nil) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status}} -> {:error, {:clickup_api_status, status}}
      {:error, reason} -> {:error, {:clickup_api_request, reason}}
    end
  end

  defp handle_list_response(%{"tasks" => []}, _list_id, _statuses, _opts, _page, acc) do
    {:ok, Enum.reverse(acc)}
  end

  defp handle_list_response(%{"tasks" => tasks}, list_id, statuses, opts, page, acc)
       when is_list(tasks) do
    request_fun = Keyword.get(opts, :request_fun, &default_request/4)

    with {:ok, headers} <- auth_headers(),
         {:ok, issues} <- normalize_tasks(tasks, request_fun, headers) do
      do_fetch_by_list_page(list_id, statuses, opts, page + 1, Enum.reverse(issues, acc))
    end
  end

  defp handle_list_response(_body, _list_id, _statuses, _opts, _page, acc) do
    {:ok, Enum.reverse(acc)}
  end

  defp do_fetch_by_ids(ids, opts) do
    request_fun = Keyword.get(opts, :request_fun, &default_request/4)

    results =
      ids
      |> Task.async_stream(
        fn task_id -> fetch_single_task(task_id, request_fun) end,
        max_concurrency: @max_parallel_fetches,
        timeout: @connect_timeout_ms * 2
      )
      |> Enum.reduce_while([], fn
        {:ok, {:ok, issue}}, acc -> {:cont, [issue | acc]}
        {:ok, {:error, reason}}, _acc -> {:halt, {:error, reason}}
        {:exit, reason}, _acc -> {:halt, {:error, {:clickup_task_fetch_exit, reason}}}
      end)

    case results do
      {:error, _reason} = error -> error
      issues when is_list(issues) -> {:ok, Enum.reverse(issues)}
    end
  end

  defp fetch_single_task(task_id, request_fun) do
    with {:ok, headers} <- auth_headers() do
      url = Config.tracker_endpoint() |> String.trim_trailing("/")
      full_url = "#{url}/task/#{task_id}"

      case request_fun.(:get, full_url, headers, nil) do
        {:ok, %{status: 200, body: task}} when is_map(task) ->
          normalize_fetched_task(task, request_fun, headers)

        {:ok, %{status: status}} ->
          {:error, {:clickup_api_status, status}}

        {:error, reason} ->
          {:error, {:clickup_api_request, reason}}
      end
    end
  end

  defp build_list_url(list_id, statuses, page) do
    base = Config.tracker_endpoint() |> String.trim_trailing("/")
    status_params = statuses |> Enum.map_join("&", &"statuses[]=#{URI.encode_www_form(&1)}")
    "#{base}/list/#{list_id}/task?#{status_params}&page=#{page}&include_closed=false"
  end

  defp normalize_fetched_task(task, request_fun, headers) do
    with {:ok, dependencies} <- fetch_dependencies_if_needed(task, request_fun, headers) do
      {:ok, normalize_task(task, dependencies)}
    end
  end

  defp normalize_tasks(tasks, request_fun, headers) when is_list(tasks) do
    results =
      tasks
      |> Task.async_stream(
        fn task ->
          with {:ok, dependencies} <- fetch_dependencies_if_needed(task, request_fun, headers) do
            {:ok, normalize_task(task, dependencies)}
          end
        end,
        max_concurrency: @max_parallel_fetches,
        timeout: @connect_timeout_ms * 2
      )
      |> Enum.reduce_while([], fn
        {:ok, {:ok, issue}}, acc -> {:cont, [issue | acc]}
        {:ok, {:error, reason}}, _acc -> {:halt, {:error, reason}}
        {:exit, reason}, _acc -> {:halt, {:error, {:clickup_dependency_fetch_exit, reason}}}
      end)

    case results do
      {:error, _reason} = error -> error
      issues when is_list(issues) -> {:ok, Enum.reverse(issues)}
    end
  end

  defp fetch_dependencies_if_needed(%{"dependencies" => deps}, _request_fun, _headers) when is_list(deps),
    do: {:ok, deps}

  defp fetch_dependencies_if_needed(%{"id" => task_id}, request_fun, headers) do
    base = Config.tracker_endpoint() |> String.trim_trailing("/")
    url = "#{base}/task/#{task_id}/dependency"

    case request_fun.(:get, url, headers, nil) do
      {:ok, %{status: 200, body: %{"dependencies" => deps}}} when is_list(deps) ->
        {:ok, deps}

      {:ok, %{status: 200, body: _body}} ->
        {:ok, []}

      {:ok, %{status: status}} ->
        {:error, {:clickup_api_status, status}}

      {:error, reason} ->
        {:error, {:clickup_api_request, reason}}
    end
  end

  defp fetch_dependencies_if_needed(_task, _request_fun, _headers), do: {:ok, []}

  defp require_token do
    case Config.tracker_api_token() do
      nil -> {:error, :missing_tracker_api_token}
      token when is_binary(token) -> {:ok, token}
    end
  end

  defp require_list_id do
    case Config.tracker_project_id() do
      nil -> {:error, :missing_tracker_project_id}
      id when is_binary(id) -> {:ok, id}
    end
  end

  defp auth_headers do
    case Config.tracker_api_token() do
      nil ->
        {:error, :missing_tracker_api_token}

      token ->
        {:ok,
         [
           {"Authorization", token},
           {"Content-Type", "application/json"}
         ]}
    end
  end

  defp default_request(method, url, headers, body) do
    req_opts = [
      method: method,
      url: url,
      headers: headers,
      connect_options: [timeout: @connect_timeout_ms]
    ]

    req_opts =
      if body do
        Keyword.put(req_opts, :json, body)
      else
        req_opts
      end

    Req.request(req_opts)
  end

  defp method_atom(method) when is_binary(method) do
    method |> String.downcase() |> String.to_existing_atom()
  end

  defp method_atom(method) when is_atom(method), do: method

  defp parse_priority(%{"id" => id}) when is_binary(id) do
    case Integer.parse(id) do
      {n, _} when n in 1..4 -> n
      _ -> nil
    end
  end

  defp parse_priority(%{"id" => id}) when is_integer(id) and id in 1..4, do: id
  defp parse_priority(_), do: nil

  defp parse_first_assignee([%{"id" => id} | _]) when is_integer(id), do: Integer.to_string(id)
  defp parse_first_assignee([%{"id" => id} | _]) when is_binary(id), do: id
  defp parse_first_assignee(_), do: nil

  defp extract_labels(%{"tags" => tags}) when is_list(tags) do
    tags
    |> Enum.map(& &1["name"])
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&String.downcase/1)
  end

  defp extract_labels(_), do: []

  defp normalize_task(task, dependencies) do
    task_with_dependencies = Map.put(task, "dependencies", dependencies)

    %Issue{
      id: task_with_dependencies["id"],
      identifier: task_with_dependencies["custom_id"] || task_with_dependencies["id"],
      title: task_with_dependencies["name"],
      description: task_with_dependencies["description"],
      priority: parse_priority(task_with_dependencies["priority"]),
      state: get_in(task_with_dependencies, ["status", "status"]),
      branch_name: nil,
      url: task_with_dependencies["url"],
      assignee_id: parse_first_assignee(task_with_dependencies["assignees"]),
      blocked_by: extract_blockers(task_with_dependencies),
      labels: extract_labels(task_with_dependencies),
      assigned_to_worker: true,
      created_at: parse_unix_ms(task_with_dependencies["date_created"]),
      updated_at: parse_unix_ms(task_with_dependencies["date_updated"])
    }
  end

  defp extract_blockers(%{"id" => task_id, "dependencies" => deps}) when is_list(deps) do
    # ClickUp dependency types:
    #   type 0 = "waiting on"  (current task depends on depends_on task)
    #   type 1 = "blocking"    (current task blocks task_id task)
    # We want blocked_by: tasks this task is waiting on → type == 0
    deps
    |> Enum.flat_map(fn
      %{"task_id" => ^task_id, "depends_on" => blocker_id, "type" => 0} ->
        [%{id: blocker_id, identifier: blocker_id, state: nil}]

      _ ->
        []
    end)
  end

  defp extract_blockers(_), do: []

  defp parse_unix_ms(ms) when is_binary(ms) do
    case Integer.parse(ms) do
      {unix_ms, _} -> DateTime.from_unix!(div(unix_ms, 1000))
      :error -> nil
    end
  end

  defp parse_unix_ms(ms) when is_integer(ms), do: DateTime.from_unix!(div(ms, 1000))
  defp parse_unix_ms(_), do: nil
end
