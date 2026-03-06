defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Executes client-side tool calls requested by Codex app-server turns.
  """

  alias SymphonyElixir.{ClickUp.Client, Config}
  alias SymphonyElixir.Linear.Client, as: LinearClient

  @linear_graphql_tool "linear_graphql"
  @clickup_api_tool "clickup_api"

  @linear_graphql_description """
  Execute a raw GraphQL query or mutation against Linear using Symphony's configured auth.
  """

  @clickup_api_description """
  Execute a guarded REST request against ClickUp using Symphony's configured auth.
  """

  @linear_graphql_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["query"],
    "properties" => %{
      "query" => %{
        "type" => "string",
        "description" => "GraphQL query or mutation document to execute against Linear."
      },
      "variables" => %{
        "type" => ["object", "null"],
        "description" => "Optional GraphQL variables object.",
        "additionalProperties" => true
      }
    }
  }

  @clickup_api_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["method", "path"],
    "properties" => %{
      "method" => %{
        "type" => "string",
        "enum" => ["GET", "POST", "PUT"],
        "description" => "HTTP method (guarded allowlist)."
      },
      "path" => %{
        "type" => "string",
        "description" => "ClickUp API path. Allowed prefixes: /task/, /list/, /team/."
      },
      "body" => %{
        "type" => ["object", "null"],
        "description" => "Optional JSON request body for POST/PUT.",
        "additionalProperties" => true
      }
    }
  }

  @allowed_clickup_methods ["GET", "POST", "PUT"]
  @allowed_clickup_path_prefixes ["/task/", "/list/", "/team/"]
  @max_clickup_request_body_bytes 10_000
  @max_clickup_response_text_bytes 50_000

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts \\ []) do
    case {Config.tracker_kind(), tool} do
      {nil, _tool} ->
        failure_response(%{
          "error" => %{
            "message" => "Tracker not configured. Set `tracker.kind` in `WORKFLOW.md`.",
            "supportedTools" => []
          }
        })

      {"linear", @linear_graphql_tool} ->
        execute_linear_graphql(arguments, opts)

      {"clickup", @clickup_api_tool} ->
        execute_clickup_api(arguments, opts)

      _other ->
        failure_response(%{
          "error" => %{
            "message" => "Unsupported dynamic tool: #{inspect(tool)}.",
            "supportedTools" => supported_tool_names()
          }
        })
    end
  end

  @spec tool_specs() :: [map()]
  def tool_specs do
    case Config.tracker_kind() do
      "linear" ->
        [
          %{
            "name" => @linear_graphql_tool,
            "description" => @linear_graphql_description,
            "inputSchema" => @linear_graphql_input_schema
          }
        ]

      "clickup" ->
        [
          %{
            "name" => @clickup_api_tool,
            "description" => @clickup_api_description,
            "inputSchema" => @clickup_api_input_schema
          }
        ]

      _ ->
        []
    end
  end

  defp execute_linear_graphql(arguments, opts) do
    linear_client = Keyword.get(opts, :linear_client, &LinearClient.graphql/3)

    with {:ok, query, variables} <- normalize_linear_graphql_arguments(arguments),
         {:ok, response} <- linear_client.(query, variables, []) do
      graphql_response(response)
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp execute_clickup_api(arguments, opts) do
    clickup_client = Keyword.get(opts, :clickup_client, &Client.rest/4)

    with {:ok, method, path, body} <- normalize_clickup_api_arguments(arguments),
         {:ok, response} <- clickup_client.(method, path, body, []),
         {:ok, text} <- encode_clickup_response(response) do
      success_response(text)
    else
      {:error, reason} ->
        failure_response(clickup_error_payload(reason))
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_binary(arguments) do
    case String.trim(arguments) do
      "" -> {:error, :missing_query}
      query -> {:ok, query, %{}}
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_map(arguments) do
    case normalize_query(arguments) do
      {:ok, query} ->
        case normalize_variables(arguments) do
          {:ok, variables} ->
            {:ok, query, variables}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_linear_graphql_arguments(_arguments), do: {:error, :invalid_arguments}

  defp normalize_clickup_api_arguments(arguments) when is_map(arguments) do
    with {:ok, method} <- normalize_clickup_method(arguments),
         {:ok, path} <- normalize_clickup_path(arguments),
         {:ok, body} <- normalize_clickup_body(arguments),
         :ok <- validate_clickup_body_for_method(method, body),
         :ok <- validate_clickup_body_size(body) do
      {:ok, method, path, body}
    end
  end

  defp normalize_clickup_api_arguments(_arguments), do: {:error, :invalid_clickup_arguments}

  defp normalize_clickup_method(arguments) do
    method = Map.get(arguments, "method") || Map.get(arguments, :method)

    case method do
      value when is_binary(value) ->
        normalized = value |> String.trim() |> String.upcase()

        if normalized in @allowed_clickup_methods do
          {:ok, normalized}
        else
          {:error, :unsupported_clickup_method}
        end

      _ ->
        {:error, :missing_clickup_method}
    end
  end

  defp normalize_clickup_path(arguments) do
    path = Map.get(arguments, "path") || Map.get(arguments, :path)

    case path do
      value when is_binary(value) ->
        trimmed = String.trim(value)

        cond do
          trimmed == "" ->
            {:error, :missing_clickup_path}

          Enum.any?(@allowed_clickup_path_prefixes, &String.starts_with?(trimmed, &1)) ->
            {:ok, trimmed}

          true ->
            {:error, :clickup_path_not_allowed}
        end

      _ ->
        {:error, :missing_clickup_path}
    end
  end

  defp normalize_clickup_body(arguments) do
    case Map.get(arguments, "body") || Map.get(arguments, :body) do
      nil -> {:ok, nil}
      body when is_map(body) -> {:ok, body}
      _ -> {:error, :invalid_clickup_body}
    end
  end

  defp validate_clickup_body_for_method("GET", body) when not is_nil(body), do: {:error, :clickup_get_body_not_allowed}
  defp validate_clickup_body_for_method(_method, _body), do: :ok

  defp validate_clickup_body_size(nil), do: :ok

  defp validate_clickup_body_size(body) when is_map(body) do
    if byte_size(Jason.encode!(body)) <= @max_clickup_request_body_bytes do
      :ok
    else
      {:error, :clickup_body_too_large}
    end
  end

  defp encode_clickup_response(response) do
    text = encode_payload(response)

    if byte_size(text) <= @max_clickup_response_text_bytes do
      {:ok, text}
    else
      {:error, :clickup_response_too_large}
    end
  end

  defp normalize_query(arguments) do
    case Map.get(arguments, "query") || Map.get(arguments, :query) do
      query when is_binary(query) ->
        case String.trim(query) do
          "" -> {:error, :missing_query}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, :missing_query}
    end
  end

  defp normalize_variables(arguments) do
    case Map.get(arguments, "variables") || Map.get(arguments, :variables) || %{} do
      variables when is_map(variables) -> {:ok, variables}
      _ -> {:error, :invalid_variables}
    end
  end

  defp graphql_response(response) do
    success =
      case response do
        %{"errors" => errors} when is_list(errors) and errors != [] -> false
        %{errors: errors} when is_list(errors) and errors != [] -> false
        _ -> true
      end

    %{
      "success" => success,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => encode_payload(response)
        }
      ]
    }
  end

  defp success_response(text) do
    %{
      "success" => true,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => text
        }
      ]
    }
  end

  defp failure_response(payload) do
    %{
      "success" => false,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => encode_payload(payload)
        }
      ]
    }
  end

  defp encode_payload(payload) when is_map(payload) or is_list(payload) do
    Jason.encode!(payload, pretty: true)
  end

  defp encode_payload(payload), do: inspect(payload)

  defp tool_error_payload(:missing_query) do
    %{
      "error" => %{
        "message" => "`linear_graphql` requires a non-empty `query` string."
      }
    }
  end

  defp tool_error_payload(:invalid_arguments) do
    %{
      "error" => %{
        "message" => "`linear_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
      }
    }
  end

  defp tool_error_payload(:invalid_variables) do
    %{
      "error" => %{
        "message" => "`linear_graphql.variables` must be a JSON object when provided."
      }
    }
  end

  defp tool_error_payload(:missing_linear_api_token) do
    %{
      "error" => %{
        "message" => "Symphony is missing Linear auth. Set `linear.api_key` in `WORKFLOW.md` or export `LINEAR_API_KEY`."
      }
    }
  end

  defp tool_error_payload({:linear_api_status, status}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed with HTTP #{status}.",
        "status" => status
      }
    }
  end

  defp tool_error_payload({:linear_api_request, reason}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed before receiving a successful response.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload(reason) do
    %{
      "error" => %{
        "message" => "Linear GraphQL tool execution failed.",
        "reason" => inspect(reason)
      }
    }
  end

  defp clickup_error_payload(:invalid_clickup_arguments) do
    %{
      "error" => %{
        "message" => "`clickup_api` expects an object with required `method` and `path`, plus optional `body`."
      }
    }
  end

  defp clickup_error_payload(:missing_clickup_method) do
    %{
      "error" => %{
        "message" => "`clickup_api.method` is required. Allowed values: GET, POST, PUT."
      }
    }
  end

  defp clickup_error_payload(:unsupported_clickup_method) do
    %{
      "error" => %{
        "message" => "`clickup_api.method` must be one of: GET, POST, PUT."
      }
    }
  end

  defp clickup_error_payload(:missing_clickup_path) do
    %{
      "error" => %{
        "message" => "`clickup_api.path` is required and must be non-empty."
      }
    }
  end

  defp clickup_error_payload(:clickup_path_not_allowed) do
    %{
      "error" => %{
        "message" => "`clickup_api.path` is not allowed. Allowed prefixes: /task/, /list/, /team/."
      }
    }
  end

  defp clickup_error_payload(:invalid_clickup_body) do
    %{
      "error" => %{
        "message" => "`clickup_api.body` must be a JSON object when provided."
      }
    }
  end

  defp clickup_error_payload(:clickup_get_body_not_allowed) do
    %{
      "error" => %{
        "message" => "`clickup_api.body` is not allowed for GET requests."
      }
    }
  end

  defp clickup_error_payload(:clickup_body_too_large) do
    %{
      "error" => %{
        "message" => "`clickup_api.body` exceeds size limit."
      }
    }
  end

  defp clickup_error_payload(:clickup_response_too_large) do
    %{
      "error" => %{
        "message" => "`clickup_api` response exceeds size limit."
      }
    }
  end

  defp clickup_error_payload(:missing_tracker_api_token) do
    %{
      "error" => %{
        "message" => "Symphony is missing tracker auth. Set `tracker.api_key` in `WORKFLOW.md` or export the tracker API key env var."
      }
    }
  end

  defp clickup_error_payload({:clickup_api_status, status}) do
    %{
      "error" => %{
        "message" => "ClickUp API request failed with HTTP #{status}.",
        "status" => status
      }
    }
  end

  defp clickup_error_payload({:clickup_api_request, _reason}) do
    %{
      "error" => %{
        "message" => "ClickUp API request failed before receiving a successful response.",
        "reason" => "transport_error"
      }
    }
  end

  defp clickup_error_payload(_reason) do
    %{
      "error" => %{
        "message" => "ClickUp API tool execution failed.",
        "reason" => "redacted"
      }
    }
  end

  defp supported_tool_names do
    Enum.map(tool_specs(), & &1["name"])
  end
end
