defmodule Jido.Chat.CapabilitiesTest do
  use ExUnit.Case, async: true

  alias Jido.Chat.{Capabilities, PostPayload, Postable}
  alias Jido.Chat.Content.{Audio, Image, Text, ToolResult, ToolUse}

  defmodule FileOperationsAdapter do
    use Jido.Chat.Adapter

    @impl true
    def transform_incoming(_), do: {:error, :unsupported}
    @impl true
    def send_message(_, _, _), do: {:error, :unsupported}
    @impl true
    def file_requirements(opts), do: Keyword.fetch!(opts, :result)
    @impl true
    def prepare_upload(room, files, opts) do
      send(self(), {:prepare, room, files})
      Keyword.fetch!(opts, :result)
    end

    @impl true
    def upload_prepared(prepared, opts) do
      send(self(), {:upload, prepared})
      Keyword.fetch!(opts, :result)
    end
  end

  test "file operation capabilities are inferred and legacy adapters remain unsupported" do
    alias Jido.Chat.Adapter

    assert Adapter.validate_capabilities(FileOperationsAdapter) == :ok
    matrix = Adapter.capabilities(FileOperationsAdapter)
    assert matrix.file_requirements == :native
    assert matrix.prepare_upload == :native
    assert matrix.upload_prepared == :native
    assert Adapter.file_requirements(__MODULE__) == {:error, :unsupported}
    assert Adapter.prepare_upload(__MODULE__, "room", []) == {:error, :unsupported}
    assert Adapter.upload_prepared(__MODULE__, %{}) == {:error, :unsupported}
  end

  defmodule MissingFileCallbacks do
    def channel_type, do: :test
    def capabilities, do: %{file_requirements: :native, prepare_upload: :native, upload_prepared: :native}
  end

  test "native file operation declarations require their exported callbacks" do
    assert {:error, {:invalid_capability_matrix, missing}} =
             Jido.Chat.Adapter.validate_capabilities(MissingFileCallbacks)

    assert {:file_requirements, :missing_callback} in missing
    assert {:prepare_upload, :missing_callback} in missing
    assert {:upload_prepared, :missing_callback} in missing
  end

  test "file limits remain independent with explicit unresolved and inapplicable values" do
    alias Jido.Chat.Adapter
    limits = %{max_file_size: 100, max_files_per_post: 10, max_upload_request_size: :unresolved}
    assert Adapter.file_requirements(FileOperationsAdapter, result: {:ok, limits}) == {:ok, limits}
    limits = %{limits | max_upload_request_size: :not_applicable}
    assert Adapter.file_requirements(FileOperationsAdapter, result: {:ok, limits}) == {:ok, limits}

    for invalid <- [
          Map.delete(limits, :max_file_size),
          %{limits | max_files_per_post: 0},
          %{limits | max_file_size: nil}
        ] do
      assert Adapter.file_requirements(FileOperationsAdapter, result: {:ok, invalid}) ==
               {:error, :invalid_file_requirements}
    end

    assert Adapter.file_requirements(FileOperationsAdapter, result: {:error, :configuration}) ==
             {:error, :configuration}
  end

  test "malformed file requirement responses are rejected at the adapter boundary" do
    for result <- [:unsupported, nil, {:ok, []}] do
      assert Jido.Chat.Adapter.file_requirements(FileOperationsAdapter, result: result) ==
               {:error, :invalid_file_requirements}
    end
  end

  test "preparation errors and malformed responses never trigger an upload or another preparation" do
    for {result, expected} <- [
          {{:error, :configuration}, {:error, :configuration}},
          {:unsupported, {:error, :invalid_prepared_upload}},
          {nil, {:error, :invalid_prepared_upload}}
        ] do
      assert Jido.Chat.Adapter.prepare_upload(FileOperationsAdapter, "room", [:candidate], result: result) ==
               expected

      assert_received {:prepare, "room", [:candidate]}
      refute_received {:prepare, _, _}
      refute_received {:upload, _}
    end
  end

  test "one exact candidate is delegated and malformed preparations cannot upload" do
    alias Jido.Chat.Adapter

    prepared = %{
      channel_id: "room",
      body: "encoded",
      content_type: "multipart/form-data; boundary=x",
      size_bytes: 7,
      files: [%{filename: "a"}]
    }

    assert Adapter.prepare_upload(FileOperationsAdapter, "room", [:candidate], result: {:ok, prepared}) ==
             {:ok, prepared}

    assert_receive {:prepare, "room", [:candidate]}
    refute_receive {:upload, _}

    for invalid <- [%{}, %{prepared | size_bytes: 8}, %{prepared | files: []}, %{prepared | channel_id: "other"}] do
      assert Adapter.prepare_upload(FileOperationsAdapter, "room", [:candidate], result: {:ok, invalid}) ==
               {:error, :invalid_prepared_upload}
    end

    assert Adapter.upload_prepared(FileOperationsAdapter, %{prepared | size_bytes: 8}) ==
             {:error, :invalid_prepared_upload}

    refute_receive {:upload, _}

    result = %{files: [%{id: "provider-id", filename: "a"}]}
    assert Adapter.upload_prepared(FileOperationsAdapter, prepared, result: {:ok, result}) == {:ok, result}
    assert_receive {:upload, ^prepared}
    refute_receive {:upload, _}

    pair = %{prepared | files: [%{filename: "a"}, %{filename: "a"}]}
    duplicates = %{files: [%{id: "same"}, %{id: "same"}]}

    assert Adapter.upload_prepared(FileOperationsAdapter, pair, result: {:ok, duplicates}) ==
             {:error, :unconfirmed_upload}

    assert_receive {:upload, ^pair}

    for files <- [[:invalid], [%{filename: "a"} | :invalid]] do
      assert Adapter.upload_prepared(FileOperationsAdapter, %{prepared | files: files}) ==
               {:error, :invalid_prepared_upload}

      refute_receive {:upload, _}
    end

    for invalid <- [
          %{},
          %{files: []},
          %{files: [%{filename: "a"}]},
          %{files: [%{id: " "}]},
          %{files: [%{id: "a"} | :invalid]}
        ] do
      assert Adapter.upload_prepared(FileOperationsAdapter, prepared, result: {:ok, invalid}) ==
               {:error, :unconfirmed_upload}

      assert_receive {:upload, ^prepared}
    end

    assert Adapter.upload_prepared(FileOperationsAdapter, prepared, result: {:error, :unconfirmed}) ==
             {:error, :unconfirmed}

    assert_receive {:upload, ^prepared}
    refute_receive {:upload, _}
  end

  test "supports?/2 and all/0" do
    assert Capabilities.supports?([:text, :image], :image)
    refute Capabilities.supports?([:text], :image)
    assert :file in Capabilities.all()
    assert :multi_file in Capabilities.all()
    assert :cards in Capabilities.all()
    refute :message_edit in Capabilities.all()
  end

  test "content_requires/1" do
    assert Capabilities.content_requires(%Text{text: "hi"}) == [:text]
    assert Capabilities.content_requires(%Image{url: "https://example.com/i.png"}) == [:image]
    assert Capabilities.content_requires(%Audio{url: "https://example.com/a.mp3"}) == [:audio]
    assert Capabilities.content_requires(%ToolUse{id: "1", name: "test"}) == [:tool_use]
    assert Capabilities.content_requires(%ToolResult{tool_use_id: "1", content: "ok"}) == [:text]
  end

  test "can_deliver?/2 and content filtering" do
    content = [
      %Text{text: "hi"},
      %Image{url: "https://example.com/i.png"},
      %Audio{url: "https://example.com/a.mp3"}
    ]

    assert Capabilities.can_deliver?([:text, :image], %Text{text: "hi"})
    refute Capabilities.can_deliver?([:text], %Image{url: "https://example.com/i.png"})

    assert [%Text{}, %Image{}] = Capabilities.filter_content(content, [:text, :image])
    assert [%Audio{}] = Capabilities.unsupported_content(content, [:text, :image])
  end

  test "can_deliver?/2 handles outbound post payloads" do
    assert Capabilities.can_deliver?(
             [:text, :file],
             Postable.text("hello", files: ["/tmp/report.pdf"])
           )

    refute Capabilities.can_deliver?(
             [:text, :file],
             Postable.text("hello", files: ["/tmp/report.pdf", "/tmp/other.pdf"])
           )

    assert Capabilities.can_deliver?(
             [:text],
             PostPayload.new(%{kind: :card, card: %{title: "Card"}, fallback_text: "fallback"})
           )

    refute Capabilities.can_deliver?(
             [:text],
             PostPayload.new(%{kind: :stream, stream: ["hello"]})
           )
  end

  test "channel_capabilities/1 derives fallbacks for adapters without an explicit matrix" do
    defmodule AdapterWithoutCapabilities do
      @behaviour Jido.Chat.Adapter

      @impl true
      def channel_type, do: :test

      @impl true
      def transform_incoming(_), do: {:error, :not_implemented}

      @impl true
      def send_message(_, _, _), do: {:error, :not_implemented}
    end

    assert Capabilities.channel_capabilities(AdapterWithoutCapabilities) == [
             :text,
             :streaming,
             :card_charts,
             :card_tables,
             :link_action_ids
           ]
  end

  test "channel_capabilities/1 derives delivery support from adapter capability matrices" do
    defmodule AdapterWithThreading do
      @behaviour Jido.Chat.Adapter

      @impl true
      def channel_type, do: :threaded

      @impl true
      def post_message(_, _, _), do: {:error, :not_implemented}

      @impl true
      def capabilities do
        %{
          send_message: :native,
          post_message: :native,
          cards: :native,
          card_charts: :fallback,
          card_tables: :native,
          modals: :native,
          modal_date_input: :native,
          modal_number_input: :fallback,
          external_select: :native,
          options_load: :native,
          link_action_ids: :fallback,
          open_thread: :native,
          list_threads: :native,
          add_reaction: :native,
          remove_reaction: :native,
          start_typing: :fallback,
          stream: :fallback
        }
      end

      @impl true
      def transform_incoming(_), do: {:error, :not_implemented}

      @impl true
      def send_message(_, _, _), do: {:error, :not_implemented}
    end

    assert Capabilities.channel_capabilities(AdapterWithThreading) == [
             :text,
             :image,
             :audio,
             :video,
             :file,
             :multi_file,
             :cards,
             :modals,
             :threads,
             :reactions,
             :typing,
             :streaming,
             :card_charts,
             :card_tables,
             :modal_date_input,
             :modal_number_input,
             :external_select,
             :options_load,
             :link_action_ids
           ]
  end

  test "channel_capabilities/1 preserves legacy list-based adapter capabilities" do
    defmodule AdapterWithLegacyListCapabilities do
      @behaviour Jido.Chat.Adapter

      @impl true
      def channel_type, do: :legacy_caps

      @impl true
      def capabilities, do: [:text, :image, :threads]

      @impl true
      def transform_incoming(_), do: {:error, :not_implemented}

      @impl true
      def send_message(_, _, _), do: {:error, :not_implemented}
    end

    assert Capabilities.channel_capabilities(AdapterWithLegacyListCapabilities) == [
             :text,
             :image,
             :threads
           ]
  end
end
