defmodule Jido.Chat.SentMessagePostTest do
  use ExUnit.Case, async: true

  alias Jido.Chat.{Attachment, ChannelRef, Postable, PostPayload, Response, Thread}

  defmodule Adapter do
    def channel_type, do: :test
    def send_message(_, _, _), do: raise("unexpected text-only dispatch")
    def capabilities, do: %{post_message: :native, multi_file: :native}

    def post_message(room, _payload, opts) do
      {:ok, Response.new(%{external_message_id: "first", external_room_id: room, metadata: opts[:response_metadata]})}
    end
  end

  test "capability matrix is coherent" do
    assert :ok = Jido.Chat.Adapter.validate_capabilities(Adapter)
  end

  defmodule ReferenceAdapter do
    def channel_type, do: :test

    def capabilities,
      do: %{post_message: :native, edit_message: :native, edit_attachments: :native, uploaded_files: :native}

    def send_message(_, _, _), do: raise("unexpected text-only dispatch")

    def post_message(room, payload, opts) do
      send(self(), {:post, room, payload, opts[:uploaded_files]})
      {:ok, Response.new(%{external_message_id: "post", external_room_id: room, metadata: %{attachments: []}})}
    end

    def edit_message(room, id, text, opts) do
      send(self(), {:edit, room, id, text, opts[:uploaded_files]})
      {:ok, Response.new(%{external_message_id: id, external_room_id: room, metadata: %{attachments: []}})}
    end
  end

  test "public posting and restored handle edits forward uploaded references without materialization" do
    alias Jido.Chat.SentMessage
    refs = [%{id: "confirmed-file", filename: "a.txt"}]
    channel = ChannelRef.new(%{id: "room", adapter: ReferenceAdapter, adapter_name: :test, external_id: "room"})
    assert :ok = Jido.Chat.Adapter.validate_capabilities(ReferenceAdapter)
    assert {:ok, sent} = ChannelRef.post(channel, "caption", uploaded_files: refs)
    assert_receive {:post, "room", %PostPayload{files: []}, ^refs}
    restored = sent |> SentMessage.to_map() |> Jason.encode!() |> Jason.decode!() |> SentMessage.from_map()
    assert {:ok, edited} = SentMessage.edit(restored, "edited", uploaded_files: refs)
    assert edited.id == "post"
    assert_receive {:edit, "room", "post", "edited", ^refs}
    refute_receive {:post, _, _, _}
    refute_receive {:edit, _, _, _, _}
  end

  test "uploaded references are invocation options and cannot restore removed attachments on later edits" do
    alias Jido.Chat.SentMessage
    refs = [%{id: "confirmed-file", filename: "a.txt"}]
    channel = ChannelRef.new(%{id: "room", adapter: ReferenceAdapter, adapter_name: :test, external_id: "room"})
    assert {:ok, sent} = ChannelRef.post(channel, "caption", uploaded_files: refs)
    assert_receive {:post, "room", _, ^refs}

    for handle <- [sent, sent |> SentMessage.to_map() |> Jason.encode!() |> Jason.decode!() |> SentMessage.from_map()] do
      assert {:ok, _} = SentMessage.edit(handle, "text only")
      assert_receive {:edit, "room", "post", "text only", nil}
    end
  end

  test "handles without saved options accept explicit references without retaining them for later edits" do
    alias Jido.Chat.SentMessage

    sent =
      SentMessage.new(%{
        adapter: ReferenceAdapter,
        response: Response.new(%{external_message_id: "post", external_room_id: "room"}),
        default_opts: nil
      })

    assert sent.default_opts == []
    restored = sent |> SentMessage.to_map() |> Jason.encode!() |> Jason.decode!() |> SentMessage.from_map()
    assert restored.default_opts == []
    refs = [%{id: "confirmed-file", filename: "a.txt"}]

    for handle <- [sent, restored] do
      assert {:ok, edited} = SentMessage.edit(handle, "attach confirmed file", uploaded_files: refs)
      assert_received {:edit, "room", "post", "attach confirmed file", ^refs}
      assert edited.id == "post"

      assert {:ok, _} = SentMessage.edit(edited, "text only")
      assert_received {:edit, "room", "post", "text only", nil}
      refute_received {:edit, _, _, _, _}
      refute_received {:post, _, _, _}
    end
  end

  test "legacy adapters reject supplied references before dropping them into a text fallback" do
    refs = [%{id: "confirmed-file"}]

    assert {:error, :uploaded_files_unsupported} =
             Jido.Chat.Adapter.post_message(Adapter, "room", PostPayload.text("caption"), uploaded_files: refs)

    assert {:error, :uploaded_files_unsupported} =
             Jido.Chat.Adapter.send_message(Adapter, "room", "caption", uploaded_files: refs)
  end

  for entry <- [Thread, ChannelRef] do
    @entry entry

    test "#{entry} keeps only the first post's attachments after split delivery" do
      first = [%{url: "https://files.test/a", filename: "a.txt"}]
      second = [%{url: "https://files.test/b", filename: "b.txt"}]

      report = %{
        confirmation: :confirmed,
        messages: [
          %{message_id: "first", metadata: %{attachments: first}},
          %{message_id: "second", metadata: %{attachments: second}}
        ]
      }

      assert {:ok, sent} = post(@entry, %{attachments: first, delivery_report: report})
      assert sent.id == "first"
      assert sent.attachments == Attachment.normalize_many(first)
      assert sent.response.metadata.delivery_report == report
    end

    test "#{entry} excludes rejected uploads from its handle" do
      delivered = [%{url: "https://files.test/a", filename: "a.txt"}]
      report = %{confirmation: :partial, failed_files: [%{filename: "b.txt", reason: :file_too_large}]}
      assert {:ok, sent} = post(@entry, %{"attachments" => delivered, "delivery_report" => report})
      assert sent.attachments == Attachment.normalize_many(delivered)
      assert sent.response.metadata["delivery_report"] == report
    end

    test "#{entry} respects an empty snapshot and falls back only when absent" do
      for key <- [:attachments, "attachments"] do
        assert {:ok, sent} = post(@entry, %{key => []})
        assert sent.attachments == []
      end

      assert {:ok, sent} = post(@entry, %{})
      assert sent.attachments == payload() |> Postable.to_payload() |> PostPayload.outbound_attachments()
    end
  end

  defp payload do
    Postable.text("files", files: [%{data: "a", filename: "a.txt"}, %{data: "b", filename: "b.txt"}])
  end

  defp post(entry, metadata) do
    target =
      case entry do
        Thread -> Thread.new(%{id: "room", adapter: Adapter, adapter_name: :test, external_room_id: "room"})
        ChannelRef -> ChannelRef.new(%{id: "room", adapter: Adapter, adapter_name: :test, external_id: "room"})
      end

    entry.post(target, payload(), response_metadata: metadata)
  end
end
