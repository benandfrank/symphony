defmodule SymphonyElixir.ClickUp.Adapter do
  @moduledoc """
  ClickUp adapter implementing the `SymphonyElixir.Tracker` behaviour.
  Delegates to `SymphonyElixir.ClickUp.Client` for API interactions.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.ClickUp.Client

  @impl true
  def fetch_candidate_issues(opts \\ []) do
    Keyword.get(opts, :fetch_candidate_issues_fun, &Client.fetch_candidate_issues/0).()
  end

  @impl true
  def fetch_issues_by_states(state_names, opts \\ []) do
    Keyword.get(opts, :fetch_issues_by_states_fun, &Client.fetch_issues_by_states/1).(state_names)
  end

  @impl true
  def fetch_issue_states_by_ids(issue_ids, opts \\ []) do
    Keyword.get(opts, :fetch_issue_states_by_ids_fun, &Client.fetch_issue_states_by_ids/1).(issue_ids)
  end

  @impl true
  def create_comment(issue_id, body, opts \\ []) do
    Keyword.get(opts, :rest_fun, &Client.rest/3).("POST", "/task/#{issue_id}/comment", %{"comment_text" => body})
    |> case do
      {:ok, _resp} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @impl true
  def update_issue_state(issue_id, state_name, opts \\ []) do
    Keyword.get(opts, :rest_fun, &Client.rest/3).("PUT", "/task/#{issue_id}", %{"status" => state_name})
    |> case do
      {:ok, _resp} -> :ok
      {:error, _reason} = error -> error
    end
  end
end
