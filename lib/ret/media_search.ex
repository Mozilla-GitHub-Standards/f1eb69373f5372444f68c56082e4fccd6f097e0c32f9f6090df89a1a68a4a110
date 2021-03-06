defmodule Ret.MediaSearchQuery do
  @enforce_keys [:source]
  defstruct [:source, :user, :filter, :q, :cursor, :locale]
end

defmodule Ret.MediaSearchResult do
  @enforce_keys [:meta, :entries]
  defstruct [:meta, :entries, :suggestions]
end

defmodule Ret.MediaSearchResultMeta do
  @enforce_keys [:source]
  defstruct [:source, :next_cursor]
end

defmodule Ret.MediaSearch do
  import Ret.HttpUtils
  import Ecto.Query

  alias Ret.{Repo, OwnedFile, Scene, SceneListing}

  @page_size 24
  @max_face_count 60000

  def search(%Ret.MediaSearchQuery{source: "scene_listings", cursor: cursor, filter: "featured", q: query}) do
    scene_listing_search(cursor, query, "featured", asc: :order)
  end

  def search(%Ret.MediaSearchQuery{source: "scene_listings", cursor: cursor, filter: filter, q: query}) do
    scene_listing_search(cursor, query, filter)
  end

  def search(%Ret.MediaSearchQuery{source: "sketchfab", cursor: cursor, filter: "featured", q: q}) do
    query =
      URI.encode_query(
        type: :models,
        downloadable: true,
        count: @page_size,
        max_face_count: @max_face_count,
        processing_status: :succeeded,
        cursor: cursor,
        collection: "ec06ae45eba24bfdb1278b223f8e289c",
        q: q
      )

    sketchfab_search(query)
  end

  def search(%Ret.MediaSearchQuery{source: "sketchfab", cursor: cursor, filter: filter, q: q}) do
    query =
      URI.encode_query(
        type: :models,
        downloadable: true,
        count: @page_size,
        max_face_count: @max_face_count,
        processing_status: :succeeded,
        cursor: cursor,
        categories: filter,
        q: q
      )

    sketchfab_search(query)
  end

  def search(%Ret.MediaSearchQuery{source: "poly", cursor: cursor, filter: filter, q: q}) do
    with api_key when is_binary(api_key) <- resolver_config(:google_poly_api_key) do
      query =
        URI.encode_query(
          pageSize: @page_size,
          maxComplexity: :MEDIUM,
          format: :GLTF2,
          pageToken: cursor,
          category: filter,
          keywords: q,
          key: api_key
        )

      res =
        "https://poly.googleapis.com/v1/assets?#{query}"
        |> retry_get_until_success()

      case res do
        :error ->
          :error

        res ->
          decoded_res = res |> Map.get(:body) |> Poison.decode!()
          entries = decoded_res |> Map.get("assets") |> Enum.map(&poly_api_result_to_entry/1)
          next_cursor = decoded_res |> Map.get("nextPageToken")

          {:commit,
           %Ret.MediaSearchResult{
             meta: %Ret.MediaSearchResultMeta{
               next_cursor: next_cursor,
               source: :poly
             },
             entries: entries
           }}
      end
    else
      _ -> nil
    end
  end

  def search(%Ret.MediaSearchQuery{source: "tenor", cursor: cursor, filter: filter, q: q}) do
    with api_key when is_binary(api_key) <- resolver_config(:tenor_api_key) do
      query =
        URI.encode_query(
          q: q,
          contentfilter: :low,
          media_filter: :minimal,
          limit: @page_size,
          pos: cursor,
          key: api_key
        )

      res =
        if filter == "trending" do
          "https://api.tenor.com/v1/trending?#{query}"
        else
          "https://api.tenor.com/v1/search?#{query}"
        end
        |> retry_get_until_success()

      case res do
        :error ->
          :error

        res ->
          decoded_res = res |> Map.get(:body) |> Poison.decode!()
          next_cursor = decoded_res |> Map.get("next")
          entries = decoded_res |> Map.get("results") |> Enum.map(&tenor_api_result_to_entry/1)

          {:commit,
           %Ret.MediaSearchResult{
             meta: %Ret.MediaSearchResultMeta{source: :tenor, next_cursor: next_cursor},
             entries: entries
           }}
      end
    else
      _ -> nil
    end
  end

  def search(%Ret.MediaSearchQuery{source: "bing_videos"} = query) do
    bing_search(query)
  end

  def search(%Ret.MediaSearchQuery{source: "bing_images"} = query) do
    bing_search(query)
  end

  def search(%Ret.MediaSearchQuery{source: "twitch", cursor: cursor, filter: _filter, q: q}) do
    with client_id when is_binary(client_id) <- resolver_config(:twitch_client_id) do
      query =
        URI.encode_query(
          query: q,
          limit: @page_size,
          offset: cursor || 0
        )

      res =
        "https://api.twitch.tv/kraken/search/streams?#{query}" |> retry_get_until_success([{"Client-ID", client_id}])

      case res do
        :error ->
          :error

        res ->
          decoded_res = res |> Map.get(:body) |> Poison.decode!()
          next_uri = decoded_res |> Map.get("_links") |> Map.get("next") |> URI.parse()
          next_cursor = next_uri.query |> URI.decode_query() |> Map.get("offset")

          entries = decoded_res |> Map.get("streams") |> Enum.map(&twitch_api_result_to_entry/1)

          {:commit,
           %Ret.MediaSearchResult{
             meta: %Ret.MediaSearchResultMeta{source: :twitch, next_cursor: next_cursor},
             entries: entries
           }}
      end
    else
      _ -> nil
    end
  end

  defp sketchfab_search(query) do
    with api_key when is_binary(api_key) <- resolver_config(:sketchfab_api_key) do
      res =
        "https://api.sketchfab.com/v3/search?#{query}"
        |> retry_get_until_success([{"Authorization", "Token #{api_key}"}])

      case res do
        :error ->
          :error

        res ->
          decoded_res = res |> Map.get(:body) |> Poison.decode!()
          entries = decoded_res |> Map.get("results") |> Enum.map(&sketchfab_api_result_to_entry/1)
          cursors = decoded_res |> Map.get("cursors")

          {:commit,
           %Ret.MediaSearchResult{
             meta: %Ret.MediaSearchResultMeta{next_cursor: cursors["next"], source: :sketchfab},
             entries: entries
           }}
      end
    else
      _ -> nil
    end
  end

  def bing_search(%Ret.MediaSearchQuery{source: source, cursor: cursor, filter: _filter, q: q, locale: locale}) do
    with api_key when is_binary(api_key) <- resolver_config(:bing_search_api_key) do
      query =
        URI.encode_query(
          count: @page_size,
          offset: cursor || 0,
          mkt: locale || "en-US",
          q: q,
          safeSearch: :Strict,
          pricing: :Free
        )

      type = source |> String.replace("bing_", "")

      res =
        "https://westus.api.cognitive.microsoft.com/bing/v7.0/#{type}/search?#{query}"
        |> retry_get_until_success([{"Ocp-Apim-Subscription-Key", api_key}])

      case res do
        :error ->
          :error

        res ->
          decoded_res = res |> Map.get(:body) |> Poison.decode!()
          next_cursor = decoded_res |> Map.get("nextOffset")
          entries = decoded_res |> Map.get("value") |> Enum.map(&bing_api_result_to_entry(type, &1))
          suggestions = decoded_res |> Map.get("relatedSearches") |> Enum.map(& &1["text"])

          {:commit,
           %Ret.MediaSearchResult{
             meta: %Ret.MediaSearchResultMeta{source: source, next_cursor: next_cursor},
             entries: entries,
             suggestions: suggestions
           }}
      end
    else
      _ -> nil
    end
  end

  defp scene_listing_search(cursor, query, filter, order \\ [desc: :updated_at]) do
    page_number = (cursor || "1") |> Integer.parse() |> elem(0)

    results =
      SceneListing
      |> join(:inner, [l], s in assoc(l, :scene))
      |> where([l, s], l.state == ^"active" and s.state == ^"active" and s.allow_promotion == ^true)
      |> add_query_to_listing_search_query(query)
      |> add_tag_to_listing_search_query(filter)
      |> preload([:screenshot_owned_file, :model_owned_file, :scene_owned_file])
      |> order_by(^order)
      |> Repo.paginate(%{page: page_number, page_size: @page_size})
      |> result_for_scene_listing_page(page_number)

    {:commit, results}
  end

  defp add_query_to_listing_search_query(query, nil), do: query
  defp add_query_to_listing_search_query(query, q), do: query |> where([l, s], ilike(l.name, ^"%#{q}%"))

  defp add_tag_to_listing_search_query(query, nil), do: query
  defp add_tag_to_listing_search_query(query, tag), do: query |> where(fragment("tags->'tags' \\? ?", ^tag))

  defp result_for_scene_listing_page(page, page_number) do
    %Ret.MediaSearchResult{
      meta: %Ret.MediaSearchResultMeta{
        next_cursor:
          if page.total_pages > page_number do
            page_number + 1
          else
            nil
          end,
        source: :scene_listings
      },
      entries:
        page.entries
        |> Enum.map(&scene_listing_to_entry/1)
    }
  end

  defp scene_listing_to_entry(scene_listing) do
    %{
      id: scene_listing.scene_listing_sid,
      url: scene_listing |> Scene.to_url(),
      type: "scene_listing",
      name: scene_listing.name,
      description: scene_listing.description,
      attributions: scene_listing.attributions,
      images: %{
        preview: %{url: scene_listing.screenshot_owned_file |> OwnedFile.uri_for() |> URI.to_string()}
      }
    }
  end

  defp sketchfab_api_result_to_entry(%{"thumbnails" => thumbnails} = result) do
    images = %{
      preview: %{
        url:
          thumbnails["images"]
          |> Enum.sort_by(fn x -> -x["size"] end)
          |> Enum.at(0)
          |> Kernel.get_in(["url"])
      }
    }

    sketchfab_api_result_to_entry(result, images)
  end

  defp sketchfab_api_result_to_entry(result) do
    sketchfab_api_result_to_entry(result, %{})
  end

  defp sketchfab_api_result_to_entry(result, images) do
    %{
      id: result["uid"],
      type: "sketchfab_model",
      name: result["name"],
      attributions: %{creator: %{name: result["user"]["username"], url: result["user"]["profileUrl"]}},
      url: "https://sketchfab.com/models/#{result["uid"]}",
      images: images
    }
  end

  defp poly_api_result_to_entry(result) do
    %{
      id: result["name"],
      type: "poly_model",
      name: result["displayName"],
      attributions: %{creator: %{name: result["authorName"]}},
      url: "https://poly.google.com/view/#{result["name"] |> String.replace("assets/", "")}",
      images: %{preview: %{url: result["thumbnail"]["url"]}}
    }
  end

  defp tenor_api_result_to_entry(result) do
    media_entry = result["media"] |> Enum.at(0)

    %{
      id: result["id"],
      type: "tenor_image",
      name: result["title"],
      attributions: %{},
      url: media_entry["mp4"]["url"],
      images: %{
        preview: %{
          url: media_entry["tinygif"]["url"],
          width: media_entry["tinygif"]["dims"] |> Enum.at(0),
          height: media_entry["tinygif"]["dims"] |> Enum.at(1)
        }
      }
    }
  end

  defp bing_api_result_to_entry(type, result) do
    object_type = type |> String.replace(~r/s$/, "")

    %{
      id: result["#{object_type}Id"],
      type: "bing_#{object_type}",
      name: result["name"],
      attributions:
        if result["publisher"] do
          %{publisher: result["publisher"] |> Enum.at(0), creator: result["creator"]}
        else
          %{}
        end,
      url: result["contentUrl"],
      images: %{
        preview: %{
          url: result["thumbnailUrl"],
          width: result["thumbnail"]["width"],
          height: result["thumbnail"]["height"]
        }
      }
    }
  end

  defp twitch_api_result_to_entry(result) do
    %{
      id: result["_id"],
      type: "twitch_stream",
      name: result["channel"]["status"],
      attributions: %{
        game: %{name: result["game"]},
        creator: %{name: result["channel"]["name"], url: result["channel"]["url"]}
      },
      url: result["channel"]["url"],
      images: %{preview: %{url: result["preview"]["large"]}}
    }
  end

  defp resolver_config(key) do
    Application.get_env(:ret, Ret.MediaResolver)[key]
  end
end
