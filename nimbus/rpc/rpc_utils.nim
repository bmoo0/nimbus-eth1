# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import hexstrings, eth/[common, rlp, keys, trie/db], stew/byteutils, nimcrypto,
  ../db/db_chain, strutils, algorithm, options, times, json,
  ../constants, stint, hexstrings, rpc_types,
  ../utils, ../transaction,
  ../transaction/call_evm

func toAddress*(value: EthAddressStr): EthAddress = hexToPaddedByteArray[20](value.string)

func toHash*(value: array[32, byte]): Hash256 {.inline.} =
  result.data = value

func toHash*(value: EthHashStr): Hash256 {.inline.} =
  result = hexToPaddedByteArray[32](value.string).toHash

func hexToInt*(s: string, T: typedesc[SomeInteger]): T =
  var i = 0
  if s[i] == '0' and (s[i+1] in {'x', 'X'}): inc(i, 2)
  if s.len - i > sizeof(T) * 2:
    raise newException(ValueError, "input hex too big for destination int")
  while i < s.len:
    result = result shl 4 or readHexChar(s[i]).T
    inc(i)

proc headerFromTag*(chain: BaseChainDB, blockTag: string): BlockHeader =
  let tag = blockTag.toLowerAscii
  case tag
  of "latest": result = chain.getCanonicalHead()
  of "earliest": result = chain.getBlockHeader(GENESIS_BLOCK_NUMBER)
  of "pending":
    #TODO: Implement get pending block
    raise newException(ValueError, "Pending tag not yet implemented")
  else:
    # Raises are trapped and wrapped in JSON when returned to the user.
    tag.validateHexQuantity
    let blockNum = stint.fromHex(UInt256, tag)
    result = chain.getBlockHeader(blockNum.toBlockNumber)

proc calculateMedianGasPrice*(chain: BaseChainDB): GasInt =
  var prices  = newSeqOfCap[GasInt](64)
  let header = chain.getCanonicalHead()
  for encodedTx in chain.getBlockTransactionData(header.txRoot):
    let tx = rlp.decode(encodedTx, Transaction)
    prices.add(tx.gasPrice)

  if prices.len > 0:
    sort(prices)
    let middle = prices.len div 2
    if prices.len mod 2 == 0:
      # prevent overflow
      let price = prices[middle].uint64 + prices[middle - 1].uint64
      result = (price div 2).GasInt
    else:
      result = prices[middle]

proc unsignedTx*(tx: TxSend, chain: BaseChainDB, defaultNonce: AccountNonce): Transaction =
  if tx.to.isSome:
    result.to = some(toAddress(tx.to.get))

  if tx.gas.isSome:
    result.gasLimit = hexToInt(tx.gas.get().string, GasInt)
  else:
    result.gasLimit = 90000.GasInt

  if tx.gasPrice.isSome:
    result.gasPrice = hexToInt(tx.gasPrice.get().string, GasInt)
  else:
    result.gasPrice = calculateMedianGasPrice(chain)

  if tx.value.isSome:
    result.value = UInt256.fromHex(tx.value.get().string)
  else:
    result.value = 0.u256

  if tx.nonce.isSome:
    result.nonce = hexToInt(tx.nonce.get().string, AccountNonce)
  else:
    result.nonce = defaultNonce

  result.payload = hexToSeqByte(tx.data.string)

proc callData*(call: EthCall, callMode: bool = true, chain: BaseChainDB): RpcCallData =
  if call.source.isSome:
    result.source = toAddress(call.source.get)

  if call.to.isSome:
    result.to = toAddress(call.to.get)
  else:
    if callMode:
      raise newException(ValueError, "call.to required for eth_call operation")
    else:
      result.contractCreation = true

  if call.gas.isSome:
    result.gas = hexToInt(call.gas.get.string, GasInt)

  if call.gasPrice.isSome:
    result.gasPrice = hexToInt(call.gasPrice.get.string, GasInt)
  else:
    if not callMode:
      result.gasPrice = calculateMedianGasPrice(chain)

  if call.value.isSome:
    result.value = UInt256.fromHex(call.value.get.string)

  if call.data.isSome:
    result.data = hexToSeqByte(call.data.get.string)

proc populateTransactionObject*(tx: Transaction, header: BlockHeader, txIndex: int): TransactionObject =
  result.blockHash = some(header.hash)
  result.blockNumber = some(encodeQuantity(header.blockNumber))
  result.`from` = tx.getSender()
  result.gas = encodeQuantity(tx.gasLimit.uint64)
  result.gasPrice = encodeQuantity(tx.gasPrice.uint64)
  result.hash = tx.rlpHash
  result.input = tx.payLoad
  result.nonce = encodeQuantity(tx.nonce.uint64)
  result.to = some(tx.destination)
  result.transactionIndex = some(encodeQuantity(txIndex.uint64))
  result.value = encodeQuantity(tx.value)
  result.v = encodeQuantity(tx.V.uint)
  result.r = encodeQuantity(tx.R)
  result.s = encodeQuantity(tx.S)

proc populateBlockObject*(header: BlockHeader, chain: BaseChainDB, fullTx: bool, isUncle = false): BlockObject =
  let blockHash = header.blockHash

  result.number = some(encodeQuantity(header.blockNumber))
  result.hash = some(blockHash)
  result.parentHash = header.parentHash
  result.nonce = some(hexDataStr(header.nonce))
  result.sha3Uncles = header.ommersHash
  result.logsBloom = some(header.bloom)
  result.transactionsRoot = header.txRoot
  result.stateRoot = header.stateRoot
  result.receiptsRoot = header.receiptRoot
  result.miner = header.coinbase
  result.difficulty = encodeQuantity(header.difficulty)
  result.extraData = hexDataStr(header.extraData)

  # discard sizeof(seq[byte]) of extraData and use actual length
  let size = sizeof(BlockHeader) - sizeof(Blob) + header.extraData.len
  result.size = encodeQuantity(size.uint)

  result.gasLimit  = encodeQuantity(header.gasLimit.uint64)
  result.gasUsed   = encodeQuantity(header.gasUsed.uint64)
  result.timestamp = encodeQuantity(header.timeStamp.toUnix.uint64)

  if not isUncle:
    result.totalDifficulty = encodeQuantity(chain.getScore(blockHash))
    result.uncles = chain.getUncleHashes(header)

    if fullTx:
      var i = 0
      for tx in chain.getBlockTransactions(header):
        result.transactions.add %(populateTransactionObject(tx, header, i))
        inc i
    else:
      for x in chain.getBlockTransactionHashes(header):
        result.transactions.add %(x)

proc populateReceipt*(receipt: Receipt, gasUsed: GasInt, tx: Transaction, txIndex: int, header: BlockHeader): ReceiptObject =
  result.transactionHash = tx.rlpHash
  result.transactionIndex = encodeQuantity(txIndex.uint)
  result.blockHash = header.hash
  result.blockNumber = encodeQuantity(header.blockNumber)
  result.`from` = tx.getSender()
  result.to = some(tx.destination)
  result.cumulativeGasUsed = encodeQuantity(receipt.cumulativeGasUsed.uint64)
  result.gasUsed = encodeQuantity(gasUsed.uint64)

  if tx.contractCreation:
    var sender: EthAddress
    if tx.getSender(sender):
      let contractAddress = generateAddress(sender, tx.nonce)
      result.contractAddress = some(contractAddress)

  result.logs = receipt.logs
  result.logsBloom = receipt.bloom

  # post-transaction stateroot (pre Byzantium).
  if receipt.hasStateRoot:
    result.root = some(receipt.stateRoot)
  else:
    # 1 = success, 0 = failure.
    result.status = some(receipt.status.int)
