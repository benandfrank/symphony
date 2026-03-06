defmodule SymphonyElixir.Linear.Issue do
  @moduledoc """
  Compatibility alias — use `SymphonyElixir.Issue` directly.

  This module is kept only as a migration shim for code that still
  references `SymphonyElixir.Linear.Issue` by name.
  """

  @type t :: SymphonyElixir.Issue.t()

  @spec label_names(t()) :: [String.t()]
  defdelegate label_names(issue), to: SymphonyElixir.Issue
end
