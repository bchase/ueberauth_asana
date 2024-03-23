defmodule Ueberauth.Strategy.Asana do
  @moduledoc """
  Asana Strategy for Überauth.
  """

  use Ueberauth.Strategy, uid_field: :id, default_scope: "default"

  alias Ueberauth.Auth.Info
  alias Ueberauth.Auth.Credentials
  alias Ueberauth.Auth.Extra

  @doc """
  Handles initial request for Asana authentication.
  """
  def handle_request!(conn) do
    scopes = conn.params["scope"] || option(conn, :default_scope)

    opts =
      [scope: scopes]
      # |> with_optional_param_or_default(:prompt, conn)
      # |> with_optional_param_or_default(:permissions, conn)
      |> with_state_param(conn)
      |> Keyword.put(:redirect_uri, callback_url(conn))

    redirect!(conn, Ueberauth.Strategy.Asana.OAuth.authorize_url!(opts))
  end

  @doc false
  def handle_callback!(%Plug.Conn{params: %{"code" => code}} = conn) do
    opts = [redirect_uri: callback_url(conn)]
    token = Ueberauth.Strategy.Asana.OAuth.get_token!([code: code], opts)

    if token.access_token == nil do
      err = token.other_params["error"]
      desc = token.other_params["error_description"]
      set_errors!(conn, [error(err, desc)])
    else
      conn
      |> store_token(token)
      |> fetch_user(token)
    end
  end

  @doc false
  def handle_callback!(conn) do
    set_errors!(conn, [error("missing_code", "No code received")])
  end

  @doc false
  def handle_cleanup!(conn) do
    conn
    |> put_private(:asana_token, nil)
    |> put_private(:asana_user, nil)
  end

  # Store the token for later use.
  @doc false
  defp store_token(conn, token) do
    put_private(conn, :asana_token, token)
  end

  defp fetch_user(conn, token) do
    path = "https://asana.com/api/users/@me"
    resp = Ueberauth.Strategy.Asana.OAuth.get(token, path)

    case resp do
      {:ok, %OAuth2.Response{status_code: 401, body: _body}} ->
        set_errors!(conn, [error("token", "unauthorized")])

      {:ok, %OAuth2.Response{status_code: status_code, body: user}}
      when status_code in 200..399 ->
        put_private(conn, :asana_user, user)

      {:error, %OAuth2.Error{reason: reason}} ->
        set_errors!(conn, [error("OAuth2", reason)])
    end
  end

  defp split_scopes(token) do
    (token.other_params["scope"] || "")
    |> String.split(" ")
  end

  @doc """
  Includes the credentials from the Asana response.
  """
  def credentials(conn) do
    token = conn.private.asana_token
    scopes = split_scopes(token)

    %Credentials{
      expires: !!token.expires_at,
      expires_at: token.expires_at,
      scopes: scopes,
      refresh_token: token.refresh_token,
      token: token.access_token
    }
  end

  @doc """
  Fetches the fields to populate the info section of the `Ueberauth.Auth` struct.
  """
  def info(conn) do
    user = conn.private.asana_user

    %Info{
      email: user["email"],
      image: fetch_image(user),
      nickname: user["username"]
    }
  end

  defp fetch_image(user) do
    if user["avatar"] do
      "https://cdn.asanaapp.com/avatars/#{user["id"]}/#{user["avatar"]}.jpg"
    else
      "https://cdn.asanaapp.com/embed/avatars/#{Integer.mod(String.to_integer(user["discriminator"]), 5)}.png"
    end
  end

  @doc """
  Stores the raw information (including the token & user)
  obtained from the Asana callback.
  """
  def extra(conn) do
    %{
      asana_token: :token,
      asana_user: :user,
    }
    |> Enum.filter(fn {original_key, _} ->
      Map.has_key?(conn.private, original_key)
    end)
    |> Enum.map(fn {original_key, mapped_key} ->
      {mapped_key, Map.fetch!(conn.private, original_key)}
    end)
    |> Map.new()
    |> (&%Extra{raw_info: &1}).()
  end

  @doc """
  Fetches the uid field from the response.
  """
  def uid(conn) do
    uid_field =
      conn
      |> option(:uid_field)
      |> to_string

    conn.private.asana_user[uid_field]
  end

  defp option(conn, key) do
    Keyword.get(options(conn), key, Keyword.get(default_options(), key))
  end

  # defp with_optional_param_or_default(opts, key, conn) do
  #   cond do
  #     value = conn.params[to_string(key)] ->
  #       Keyword.put(opts, key, value)

  #     default_opt = option(conn, key) ->
  #       Keyword.put(opts, key, default_opt)

  #     true ->
  #       opts
  #   end
  # end
end