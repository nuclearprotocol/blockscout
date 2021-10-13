defmodule Indexer.Transform.TokenTransfers do
  @moduledoc """
  Helper functions for transforming data for ERC-20 and ERC-721 token transfers.
  """

  require Logger

  alias ABI.TypeDecoder
  alias Explorer.{Chain, Repo}
  alias Explorer.Chain.{Token, TokenTransfer}
  alias Explorer.Token.MetadataRetriever

  @burn_address "0x0000000000000000000000000000000000000000"
  @deposit_constant "0xe1fffcc4923d04b559f4d29a8bfc6cda04eb5b0d3c460751c2402c5c5cc9109c"
  @withdrawal_constant "0x7fcf532c15f0a6db0bd6d0e038bea71d30d808c7d98cb3bf7268a95bf5081b65"

  @doc """
  Returns a list of token transfers given a list of logs.
  """
  def parse(logs) do
    initial_acc = %{tokens: [], token_transfers: []}

    logs
    |> Enum.filter(fn log ->
      Enum.member?([unquote(TokenTransfer.constant()), @deposit_constant, @withdrawal_constant], log.first_topic)
    end)
    |> Enum.reduce(initial_acc, &do_parse/2)
  end

  defp do_parse(log, %{tokens: tokens, token_transfers: token_transfers} = acc) do
    {token, token_transfer} = parse_params(log)

    %{
      tokens: [token | tokens],
      token_transfers: [token_transfer | token_transfers]
    }
  rescue
    _ in [FunctionClauseError, MatchError] ->
      Logger.error(fn -> "Unknown token transfer format: #{inspect(log)}" end)
      acc
  end

  # ERC-20 token transfer
  defp parse_params(%{first_topic: first_topic, second_topic: second_topic, third_topic: third_topic, fourth_topic: nil} = log)
       when not is_nil(second_topic) and not is_nil(third_topic) and first_topic == unquote(TokenTransfer.constant()) do
    [amount] = decode_data(log.data, [{:uint, 256}])

    token_transfer = %{
      amount: Decimal.new(amount || 0),
      block_number: log.block_number,
      block_hash: log.block_hash,
      log_index: log.index,
      from_address_hash: truncate_address_hash(log.second_topic),
      to_address_hash: truncate_address_hash(log.third_topic),
      token_contract_address_hash: log.address_hash,
      transaction_hash: log.transaction_hash,
      token_type: "ERC-20"
    }

    token = %{
      contract_address_hash: log.address_hash,
      type: "ERC-20"
    }

    update_token(log.address_hash, token_transfer)

    {token, token_transfer}
  end

  # ERC-20 token deposit
  defp parse_params(%{first_topic: first_topic, second_topic: second_topic, third_topic: nil, fourth_topic: nil} = log)
       when not is_nil(second_topic) and first_topic == @deposit_constant do
    [amount] = decode_data(log.data, [{:uint, 256}])

    token_transfer = %{
      amount: Decimal.new(amount || 0),
      block_number: log.block_number,
      block_hash: log.block_hash,
      log_index: log.index,
      from_address_hash: @burn_address,
      to_address_hash: truncate_address_hash(log.second_topic),
      token_contract_address_hash: log.address_hash,
      transaction_hash: log.transaction_hash,
      token_type: "ERC-20"
    }

    token = %{
      contract_address_hash: log.address_hash,
      type: "ERC-20"
    }

    update_token(log.address_hash, token_transfer)

    {token, token_transfer}
  end

  # ERC-20 token withdrawal
  defp parse_params(%{first_topic: first_topic, second_topic: second_topic, third_topic: nil, fourth_topic: nil} = log)
       when not is_nil(second_topic) and first_topic == @withdrawal_constant do
    [amount] = decode_data(log.data, [{:uint, 256}])

    token_transfer = %{
      amount: Decimal.new(amount || 0),
      block_number: log.block_number,
      block_hash: log.block_hash,
      log_index: log.index,
      from_address_hash: truncate_address_hash(log.second_topic),
      to_address_hash: @burn_address,
      token_contract_address_hash: log.address_hash,
      transaction_hash: log.transaction_hash,
      token_type: "ERC-20"
    }

    token = %{
      contract_address_hash: log.address_hash,
      type: "ERC-20"
    }

    update_token(log.address_hash, token_transfer)

    {token, token_transfer}
  end

  # ERC-721 token transfer with topics as addresses
  defp parse_params(%{first_topic: first_topic, second_topic: second_topic, third_topic: third_topic, fourth_topic: fourth_topic} = log)
       when not is_nil(second_topic) and not is_nil(third_topic) and not is_nil(fourth_topic) and first_topic == unquote(TokenTransfer.constant()) do
    [token_id] = decode_data(fourth_topic, [{:uint, 256}])

    token_transfer = %{
      block_number: log.block_number,
      log_index: log.index,
      block_hash: log.block_hash,
      from_address_hash: truncate_address_hash(log.second_topic),
      to_address_hash: truncate_address_hash(log.third_topic),
      token_contract_address_hash: log.address_hash,
      token_id: token_id || 0,
      transaction_hash: log.transaction_hash,
      token_type: "ERC-721"
    }

    token = %{
      contract_address_hash: log.address_hash,
      type: "ERC-721"
    }

    update_token(log.address_hash, token_transfer)

    {token, token_transfer}
  end

  # ERC-721 token transfer with info in data field instead of in log topics
  defp parse_params(%{first_topic: first_topic, second_topic: nil, third_topic: nil, fourth_topic: nil, data: data} = log)
       when not is_nil(data) and first_topic == unquote(TokenTransfer.constant()) do
    [from_address_hash, to_address_hash, token_id] = decode_data(data, [:address, :address, {:uint, 256}])

    token_transfer = %{
      block_number: log.block_number,
      block_hash: log.block_hash,
      log_index: log.index,
      from_address_hash: encode_address_hash(from_address_hash),
      to_address_hash: encode_address_hash(to_address_hash),
      token_contract_address_hash: log.address_hash,
      token_id: token_id,
      transaction_hash: log.transaction_hash,
      token_type: "ERC-721"
    }

    token = %{
      contract_address_hash: log.address_hash,
      type: "ERC-721"
    }

    update_token(log.address_hash, token_transfer)

    {token, token_transfer}
  end

  defp update_token(address_hash_string, token_transfer) do
    if token_transfer.to_address_hash == @burn_address || token_transfer.from_address_hash == @burn_address do
      {:ok, address_hash} = Chain.string_to_address_hash(address_hash_string)

      token_params =
        address_hash_string
        |> MetadataRetriever.get_functions_of()

      token = Repo.get_by(Token, contract_address_hash: address_hash)

      if token do
        token_to_update =
          token
          |> Repo.preload([:contract_address])

        {:ok, _} = Chain.update_token(%{token_to_update | updated_at: DateTime.utc_now()}, token_params)
      end
    end

    :ok
  end

  defp truncate_address_hash(nil), do: "0x0000000000000000000000000000000000000000"

  defp truncate_address_hash("0x000000000000000000000000" <> truncated_hash) do
    "0x#{truncated_hash}"
  end

  defp encode_address_hash(binary) do
    "0x" <> Base.encode16(binary, case: :lower)
  end

  defp decode_data("0x", types) do
    for _ <- types, do: nil
  end

  defp decode_data("0x" <> encoded_data, types) do
    encoded_data
    |> Base.decode16!(case: :mixed)
    |> TypeDecoder.decode_raw(types)
  end
end
