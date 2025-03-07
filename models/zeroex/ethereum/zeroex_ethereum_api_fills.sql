{{  config(
        alias='api_fills',
        materialized='incremental',
        partition_by = ['block_date'],
        unique_key = ['block_date', 'tx_hash', 'evt_index'],
        on_schema_change='sync_all_columns',
        file_format ='delta',
        incremental_strategy='merge' 
    )
}}

{% set zeroex_v3_start_date = '2019-12-01' %}
{% set zeroex_v4_start_date = '2021-01-06' %}

-- Test Query here: https://dune.com/queries/1330551
WITH zeroex_tx AS (
    SELECT tx_hash,
           max(affiliate_address) as affiliate_address
    FROM (

        SELECT v3.evt_tx_hash AS tx_hash,
                    CASE
                        WHEN takerAddress = '0x63305728359c088a52b0b0eeec235db4d31a67fc' THEN takerAddress
                        ELSE NULL
                    END AS affiliate_address
        FROM {{ source('zeroex_v3_ethereum', 'Exchange_evt_Fill') }} v3
        WHERE (  -- nuo
                v3.takerAddress = '0x63305728359c088a52b0b0eeec235db4d31a67fc'
                OR -- contains a bridge order
                (
                    v3.feeRecipientAddress = '0x1000000000000000000000000000000000000011'
                    AND SUBSTRING(v3.makerAssetData, 1, 10) = '0xdc1600f3'
                )
            )

            {% if is_incremental() %}
            AND evt_block_time >= date_trunc('day', now() - interval '1 week')
            {% endif %}
            {% if not is_incremental() %}
            AND evt_block_time >= '{{zeroex_v3_start_date}}'
            {% endif %}

        UNION ALL
        SELECT tr.tx_hash,
                    '0x' || CASE
                                WHEN POSITION('869584cd' IN INPUT) <> 0
                                THEN SUBSTRING(INPUT
                                        FROM (position('869584cd' IN INPUT) + 32)
                                        FOR 40)
                                WHEN POSITION('fbc019a7' IN INPUT) <> 0
                                THEN SUBSTRING(INPUT
                                        FROM (position('fbc019a7' IN INPUT) + 32)
                                        FOR 40)
                            END AS affiliate_address
        FROM {{ source('ethereum', 'traces') }} tr
        WHERE tr.to IN (
                -- exchange contract
                '0x61935cbdd02287b511119ddb11aeb42f1593b7ef',
                -- forwarder addresses
                '0x6958f5e95332d93d21af0d7b9ca85b8212fee0a5',
                '0x4aa817c6f383c8e8ae77301d18ce48efb16fd2be',
                '0x4ef40d1bf0983899892946830abf99eca2dbc5ce',
                -- exchange proxy
                '0xdef1c0ded9bec7f1a1670819833240f027b25eff'
                )
                AND (
                        POSITION('869584cd' IN INPUT) <> 0
                        OR POSITION('fbc019a7' IN INPUT) <> 0
                    )

                {% if is_incremental() %}
                AND block_time >= date_trunc('day', now() - interval '1 week')
                {% endif %}
                {% if not is_incremental() %}
                AND block_time >= '{{zeroex_v3_start_date}}'
                {% endif %}
    ) temp
    group by tx_hash

),
v3_fills_no_bridge AS (
    SELECT
            fills.evt_tx_hash                                                          AS tx_hash,
            fills.evt_index,
            fills.contract_address,
            evt_block_time                                                             AS block_time,
            fills.makerAddress                                                         AS maker,
            fills.takerAddress                                                         AS taker,
            '0x' || SUBSTRING(fills.takerAssetData, 35, 40)                            AS taker_token,
            '0x' || SUBSTRING(fills.makerAssetData, 35, 40)                            AS maker_token,
            fills.takerAssetFilledAmount                                               AS taker_token_amount_raw,
            fills.makerAssetFilledAmount                                               AS maker_token_amount_raw,
            'Fill'                                                                     AS type,
            COALESCE(zeroex_tx.affiliate_address, fills.feeRecipientAddress)           AS affiliate_address,
            (zeroex_tx.tx_hash IS NOT NULL)                                            AS swap_flag,
            (fills.feeRecipientAddress = '0x86003b044f70dac0abc80ac8957305b6370893ed') AS matcha_limit_order_flag
    FROM {{ source('zeroex_v3_ethereum', 'Exchange_evt_Fill') }} fills
    LEFT JOIN zeroex_tx ON zeroex_tx.tx_hash = fills.evt_tx_hash
    WHERE (SUBSTRING(makerAssetData, 1, 10) != '0xdc1600f3')
        AND (zeroex_tx.tx_hash IS NOT NULL
        OR fills.feeRecipientAddress = '0x86003b044f70dac0abc80ac8957305b6370893ed')

        {% if is_incremental() %}
         AND evt_block_time >= date_trunc('day', now() - interval '1 week')
        {% endif %}
        {% if not is_incremental() %}
         AND evt_block_time >= '{{zeroex_v3_start_date}}'
        {% endif %}

),
v4_rfq_fills_no_bridge AS (
    SELECT
            fills.evt_tx_hash               AS tx_hash,
            fills.evt_index,
            fills.contract_address,
            fills.evt_block_time            AS block_time,
            fills.maker                     AS maker,
            fills.taker                     AS taker,
            fills.takerToken                AS taker_token,
            fills.makerToken                AS maker_token,
            fills.takerTokenFilledAmount    AS taker_token_amount_raw,
            fills.makerTokenFilledAmount    AS maker_token_amount_raw,
            'RfqOrderFilled'                AS type,
            zeroex_tx.affiliate_address     AS affiliate_address,
            (zeroex_tx.tx_hash IS NOT NULL) AS swap_flag,
            FALSE                           AS matcha_limit_order_flag
    FROM {{ source('zeroex_ethereum', 'ExchangeProxy_evt_RfqOrderFilled') }} fills
    LEFT JOIN zeroex_tx ON zeroex_tx.tx_hash = fills.evt_tx_hash

    {% if is_incremental() %}
    WHERE evt_block_time >= date_trunc('day', now() - interval '1 week')
    {% endif %}
    {% if not is_incremental() %}
    WHERE evt_block_time >= '{{zeroex_v4_start_date}}'
    {% endif %}
),
v4_limit_fills_no_bridge AS (
    SELECT
            fills.evt_tx_hash AS tx_hash,
            fills.evt_index,
            fills.contract_address,
            fills.evt_block_time AS block_time,
            fills.maker AS maker,
            fills.taker AS taker,
            fills.takerToken AS taker_token,
            fills.makerToken AS maker_token,
            fills.takerTokenFilledAmount AS taker_token_amount_raw,
            fills.makerTokenFilledAmount AS maker_token_amount_raw,
            'LimitOrderFilled' AS type,
            COALESCE(zeroex_tx.affiliate_address, fills.feeRecipient) AS affiliate_address,
            (zeroex_tx.tx_hash IS NOT NULL) AS swap_flag,
            (fills.feeRecipient in 
                ('0x9b858be6e3047d88820f439b240deac2418a2551','0x86003b044f70dac0abc80ac8957305b6370893ed','0x5bc2419a087666148bfbe1361ae6c06d240c6131')) 
                AS matcha_limit_order_flag
    FROM {{ source('zeroex_ethereum', 'ExchangeProxy_evt_LimitOrderFilled') }} fills
    LEFT JOIN zeroex_tx ON zeroex_tx.tx_hash = fills.evt_tx_hash

    {% if is_incremental() %}
    WHERE evt_block_time >= date_trunc('day', now() - interval '1 week')
    {% endif %}
    {% if not is_incremental() %}
    WHERE evt_block_time >= '{{zeroex_v4_start_date}}'
    {% endif %}
),
otc_fills AS (
    SELECT
            fills.evt_tx_hash               AS tx_hash,
            fills.evt_index,
            fills.contract_address,
            fills.evt_block_time            AS block_time,
            fills.maker                     AS maker,
            fills.taker                     AS taker,
            fills.takerToken                AS taker_token,
            fills.makerToken                AS maker_token,
            fills.takerTokenFilledAmount    AS taker_token_amount_raw,
            fills.makerTokenFilledAmount    AS maker_token_amount_raw,
            'OtcOrderFilled'                AS type,
            zeroex_tx.affiliate_address     AS affiliate_address,
            (zeroex_tx.tx_hash IS NOT NULL) AS swap_flag,
            FALSE                           AS matcha_limit_order_flag
    FROM {{ source('zeroex_ethereum', 'ExchangeProxy_evt_OtcOrderFilled') }} fills
    LEFT JOIN zeroex_tx ON zeroex_tx.tx_hash = fills.evt_tx_hash

    {% if is_incremental() %}
    WHERE evt_block_time >= date_trunc('day', now() - interval '1 week')
    {% endif %}
    {% if not is_incremental() %}
    WHERE evt_block_time >= '{{zeroex_v4_start_date}}'
    {% endif %}

),
ERC20BridgeTransfer AS (
    SELECT
            logs.tx_hash,
            INDEX                                   AS evt_index,
            logs.contract_address,
            block_time                              AS block_time,
            '0x' || substring(DATA, 283, 40)        AS maker,
            '0x' || substring(DATA, 347, 40)        AS taker,
            '0x' || substring(DATA, 27, 40)         AS taker_token,
            '0x' || substring(DATA, 91, 40)         AS maker_token,
            bytea2numeric_v3(substring(DATA, 155, 40)) AS taker_token_amount_raw,
            bytea2numeric_v3(substring(DATA, 219, 40)) AS maker_token_amount_raw,
            'ERC20BridgeTransfer'                   AS type,
            zeroex_tx.affiliate_address             AS affiliate_address,
            TRUE                                    AS swap_flag,
            FALSE                                   AS matcha_limit_order_flag
    FROM {{ source('ethereum', 'logs') }} logs
    JOIN zeroex_tx ON zeroex_tx.tx_hash = logs.tx_hash
    WHERE topic1 = '0x349fc08071558d8e3aa92dec9396e4e9f2dfecd6bb9065759d1932e7da43b8a9'

    {% if is_incremental() %}
    AND block_time >= date_trunc('day', now() - interval '1 week')
    {% endif %}
    {% if not is_incremental() %}
    AND block_time >= '{{zeroex_v3_start_date}}'
    {% endif %}

),
BridgeFill AS (
    SELECT
            logs.tx_hash,
            INDEX                                           AS evt_index,
            logs.contract_address,
            block_time                                      AS block_time,
            '0x' || substring(DATA, 27, 40)                 AS maker,
            '0xdef1c0ded9bec7f1a1670819833240f027b25eff'    AS taker,
            '0x' || substring(DATA, 91, 40)                 AS taker_token,
            '0x' || substring(DATA, 155, 40)                AS maker_token,
            bytea2numeric_v3('0x' || substring(DATA, 219, 40)) AS taker_token_amount_raw,
            bytea2numeric_v3('0x' || substring(DATA, 283, 40)) AS maker_token_amount_raw,
            'BridgeFill'                                    AS type,
            zeroex_tx.affiliate_address                     AS affiliate_address,
            TRUE                                            AS swap_flag,
            FALSE                                           AS matcha_limit_order_flag
    FROM {{ source('ethereum', 'logs') }} logs
    JOIN zeroex_tx ON zeroex_tx.tx_hash = logs.tx_hash
    WHERE topic1 = '0xff3bc5e46464411f331d1b093e1587d2d1aa667f5618f98a95afc4132709d3a9'
        AND contract_address = '0x22f9dcf4647084d6c31b2765f6910cd85c178c18'

        {% if is_incremental() %}
        AND block_time >= date_trunc('day', now() - interval '1 week')
        {% endif %}
        {% if not is_incremental() %}
        AND block_time >= '{{zeroex_v4_start_date}}'
        {% endif %}
),
NewBridgeFill AS (
    SELECT
            logs.tx_hash,
            INDEX                                           AS evt_index,
            logs.contract_address,
            block_time                                      AS block_time,
            '0x' || substring(DATA, 27, 40)                 AS maker,
            '0xdef1c0ded9bec7f1a1670819833240f027b25eff'    AS taker,
            '0x' || substring(DATA, 91, 40)                 AS taker_token,
            '0x' || substring(DATA, 155, 40)                AS maker_token,
            bytea2numeric_v3('0x' || substring(DATA, 219, 40)) AS taker_token_amount_raw,
            bytea2numeric_v3('0x' || substring(DATA, 283, 40)) AS maker_token_amount_raw,
            'NewBridgeFill'                                 AS type,
            zeroex_tx.affiliate_address                     AS affiliate_address,
            TRUE                                            AS swap_flag,
            FALSE                                           AS matcha_limit_order_flag
    FROM {{ source('ethereum' ,'logs') }} logs
    JOIN zeroex_tx ON zeroex_tx.tx_hash = logs.tx_hash
    WHERE topic1 = '0xe59e71a14fe90157eedc866c4f8c767d3943d6b6b2e8cd64dddcc92ab4c55af8'
        AND contract_address = '0x22f9dcf4647084d6c31b2765f6910cd85c178c18'

        {% if is_incremental() %}
        AND block_time >= date_trunc('day', now() - interval '1 week')
        {% endif %}
        {% if not is_incremental() %}
        AND block_time >= '{{zeroex_v4_start_date}}'
        {% endif %}
),
direct_PLP AS (
    SELECT
            plp.evt_tx_hash,
            plp.evt_index               AS evt_index,
            plp.contract_address,
            plp.evt_block_time          AS block_time,
            provider                    AS maker,
            recipient                   AS taker,
            inputToken                  AS taker_token,
            outputToken                 AS maker_token,
            inputTokenAmount            AS taker_token_amount_raw,
            outputTokenAmount           AS maker_token_amount_raw,
            'LiquidityProviderSwap'     AS type,
            zeroex_tx.affiliate_address AS affiliate_address,
            TRUE                        AS swap_flag,
            FALSE                       AS matcha_limit_order_flag
    FROM {{ source('zeroex_ethereum', 'ExchangeProxy_evt_LiquidityProviderSwap') }} plp
    JOIN zeroex_tx ON zeroex_tx.tx_hash = plp.evt_tx_hash

    {% if is_incremental() %}
    WHERE evt_block_time >= date_trunc('day', now() - interval '1 week')
    {% endif %}
    {% if not is_incremental() %}
    WHERE evt_block_time >= '{{zeroex_v3_start_date}}'
    {% endif %}

),
direct_uniswapv2 AS (
    SELECT
            swap.evt_tx_hash AS tx_hash,
            swap.evt_index,
            swap.contract_address,
            swap.evt_block_time AS block_time,
            swap.contract_address AS maker,
            LAST_VALUE(swap.to) OVER ( PARTITION BY swap.evt_tx_hash ORDER BY swap.evt_index) AS taker,
            CASE
                WHEN CAST(swap.amount0In AS float) > CAST(swap.amount0Out AS float) THEN pair.token0
                ELSE pair.token1
            END AS taker_token,
            CASE
                WHEN CAST(swap.amount0In AS float) > CAST(swap.amount0Out AS float) THEN pair.token1
                ELSE pair.token0
            END AS maker_token,
            CASE
                WHEN CAST(swap.amount0In AS float) > CAST(swap.amount0Out AS float) THEN swap.amount0In - swap.amount0Out
                ELSE swap.amount1In - swap.amount1Out
            END AS taker_token_amount_raw,
            CASE
                WHEN CAST(swap.amount0In AS float) > CAST(swap.amount0Out AS float) THEN swap.amount1Out - swap.amount1In
                ELSE swap.amount0Out - swap.amount0In
            END AS maker_token_amount_raw,
            'Uniswap V2 Direct' AS type,
            zeroex_tx.affiliate_address AS affiliate_address,
            TRUE AS swap_flag,
            FALSE AS matcha_limit_order_flag
    FROM {{ source('uniswap_v2_ethereum', 'Pair_evt_Swap') }} swap
    LEFT JOIN {{ source('uniswap_v2_ethereum', 'Factory_evt_PairCreated') }} pair ON pair.pair = swap.contract_address
    JOIN zeroex_tx ON zeroex_tx.tx_hash = swap.evt_tx_hash
    WHERE sender = '0xdef1c0ded9bec7f1a1670819833240f027b25eff'

        {% if is_incremental() %}
        AND swap.evt_block_time >= date_trunc('day', now() - interval '1 week')
        {% endif %}
        {% if not is_incremental() %}
        AND swap.evt_block_time >= '{{zeroex_v3_start_date}}'
        {% endif %}

),
direct_sushiswap AS (
    SELECT
            swap.evt_tx_hash AS tx_hash,
            swap.evt_index,
            swap.contract_address,
            swap.evt_block_time AS block_time,
            swap.contract_address AS maker,
            LAST_VALUE(swap.to) OVER (PARTITION BY swap.evt_tx_hash ORDER BY swap.evt_index) AS taker,
            CASE
                WHEN CAST(swap.amount0In AS float) > CAST(swap.amount0Out AS float) THEN pair.token0
                ELSE pair.token1
            END AS taker_token,
            CASE
                WHEN CAST(swap.amount0In AS float) > CAST(swap.amount0Out AS float) THEN pair.token1
                ELSE pair.token0
            END AS maker_token,
            CASE
                WHEN CAST(swap.amount0In AS float) > CAST(swap.amount0Out AS float) THEN swap.amount0In - swap.amount0Out
                ELSE swap.amount1In - swap.amount1Out
            END AS taker_token_amount_raw,
            CASE
                WHEN CAST(swap.amount0In AS float) > CAST(swap.amount0Out AS float) THEN swap.amount1Out - swap.amount1In
                ELSE swap.amount0Out - swap.amount0In
            END AS maker_token_amount_raw,
            'Sushiswap Direct' AS type,
            zeroex_tx.affiliate_address AS affiliate_address,
            TRUE AS swap_flag,
            FALSE AS matcha_limit_order_flag
   FROM {{ source('sushi_ethereum', 'Pair_evt_Swap') }} swap
   LEFT JOIN {{ source('sushi_ethereum', 'Factory_evt_PairCreated') }} pair ON pair.pair = swap.contract_address
   JOIN zeroex_tx ON zeroex_tx.tx_hash = swap.evt_tx_hash
   WHERE sender = '0xdef1c0ded9bec7f1a1670819833240f027b25eff'

        {% if is_incremental() %}
        AND swap.evt_block_time >= date_trunc('day', now() - interval '1 week')
        {% endif %}
        {% if not is_incremental() %}
        AND swap.evt_block_time >= '{{zeroex_v3_start_date}}'
        {% endif %}
),
direct_uniswapv3 AS (
    SELECT
            swap.evt_tx_hash                                                                        AS tx_hash,
            swap.evt_index,
            swap.contract_address,
            swap.evt_block_time                                                                     AS block_time,
            swap.contract_address                                                                   AS maker,
            LAST_VALUE(swap.recipient) OVER (PARTITION BY swap.evt_tx_hash ORDER BY swap.evt_index) AS taker,
            CASE WHEN amount0 < '0' THEN pair.token1 ELSE pair.token0 END                           AS taker_token,
            CASE WHEN amount0 < '0' THEN pair.token0 ELSE pair.token1 END                           AS maker_token,
            CASE
                WHEN amount0 < '0' THEN abs(swap.amount1)
                ELSE abs(swap.amount0) END                                                          AS taker_token_amount_raw,
            CASE
                WHEN amount0 < '0' THEN abs(swap.amount0)
                ELSE abs(swap.amount1) END                                                          AS maker_token_amount_raw,
            'Uniswap V3 Direct'                                                                     AS type,
            zeroex_tx.affiliate_address                                                             AS affiliate_address,
            TRUE                                                                                    AS swap_flag,
            FALSE                                                                                   AS matcha_limit_order_flag
    FROM {{ source('uniswap_v3_ethereum', 'Pair_evt_Swap') }} swap
   LEFT JOIN {{ source('uniswap_v3_ethereum', 'Factory_evt_PoolCreated') }} pair ON pair.pool = swap.contract_address
   JOIN zeroex_tx ON zeroex_tx.tx_hash = swap.evt_tx_hash
   WHERE sender = '0xdef1c0ded9bec7f1a1670819833240f027b25eff'

        {% if is_incremental() %}
        AND swap.evt_block_time >= date_trunc('day', now() - interval '1 week')
        {% endif %}
        {% if not is_incremental() %}
        AND swap.evt_block_time >= '{{zeroex_v4_start_date}}'
        {% endif %}

),
all_tx AS (
    SELECT *
    FROM direct_uniswapv2
    UNION ALL SELECT *
    FROM direct_uniswapv3
    UNION ALL SELECT *
    FROM direct_sushiswap
    UNION ALL SELECT *
    FROM direct_PLP
    UNION ALL SELECT *
    FROM ERC20BridgeTransfer
    UNION ALL SELECT *
    FROM BridgeFill
    UNION ALL SELECT *
    FROM NewBridgeFill
    UNION ALL SELECT *
    FROM v3_fills_no_bridge
    UNION ALL SELECT *
    FROM v4_rfq_fills_no_bridge
    UNION ALL SELECT *
    FROM v4_limit_fills_no_bridge
    UNION ALL SELECT *
    FROM otc_fills
)

SELECT
        all_tx.tx_hash,
        tx.block_number,
        all_tx.evt_index,
        all_tx.contract_address,
        all_tx.block_time,
        try_cast(date_trunc('day', all_tx.block_time) AS date) AS block_date,
        maker,
        CASE
            WHEN taker = '0xdef1c0ded9bec7f1a1670819833240f027b25eff' THEN tx.from
            ELSE taker
        END AS taker, -- fix the user masked by ProxyContract issue
        taker_token,
        ts.symbol AS taker_symbol,
        maker_token, 
        ms.symbol AS maker_symbol,
        CASE WHEN lower(ts.symbol) > lower(ms.symbol) THEN concat(ms.symbol, '-', ts.symbol) ELSE concat(ts.symbol, '-', ms.symbol) END AS token_pair,
        taker_token_amount_raw / pow(10, tp.decimals) AS taker_token_amount,
        taker_token_amount_raw,
        maker_token_amount_raw / pow(10, mp.decimals) AS maker_token_amount,
        maker_token_amount_raw,
        all_tx.type,
        affiliate_address,
        swap_flag,
        matcha_limit_order_flag,
        CASE WHEN maker_token IN ('0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2','0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48','0xdac17f958d2ee523a2206206994597c13d831ec7',
                '0x4fabb145d64652a948d72533023f6e7a623c7c53','0x6b175474e89094c44da98b954eedeac495271d0f') AND  mp.price IS NOT NULL
             THEN (all_tx.maker_token_amount_raw / pow(10, mp.decimals)) * mp.price
             WHEN taker_token IN ('0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2','0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48','0xdac17f958d2ee523a2206206994597c13d831ec7',
                '0x4fabb145d64652a948d72533023f6e7a623c7c53','0x6b175474e89094c44da98b954eedeac495271d0f')  AND  tp.price IS NOT NULL
             THEN (all_tx.taker_token_amount_raw / pow(10, tp.decimals)) * tp.price
             ELSE COALESCE((all_tx.maker_token_amount_raw / pow(10, mp.decimals)) * mp.price, (all_tx.taker_token_amount_raw / pow(10, tp.decimals)) * tp.price)
             END AS volume_usd,
        tx.from AS tx_from,
        tx.to AS tx_to,
        'ethereum' AS blockchain
FROM all_tx
INNER JOIN {{ source('ethereum', 'transactions')}} tx ON all_tx.tx_hash = tx.hash

{% if is_incremental() %}
AND tx.block_time >= date_trunc('day', now() - interval '1 week')
{% endif %}
{% if not is_incremental() %}
AND tx.block_time >= '{{zeroex_v3_start_date}}'
{% endif %}

LEFT JOIN {{ source('prices', 'usd') }} tp ON date_trunc('minute', all_tx.block_time) = tp.minute
AND CASE
        WHEN all_tx.taker_token = '0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee' THEN '0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2'
        ELSE all_tx.taker_token
    END = tp.contract_address
AND tp.blockchain = 'ethereum'

{% if is_incremental() %}
AND tp.minute >= date_trunc('day', now() - interval '1 week')
{% endif %}
{% if not is_incremental() %}
AND tp.minute >= '{{zeroex_v3_start_date}}'
{% endif %}

LEFT JOIN {{ source('prices', 'usd') }} mp ON DATE_TRUNC('minute', all_tx.block_time) = mp.minute
AND CASE
        WHEN all_tx.maker_token = '0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee' THEN '0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2'
        ELSE all_tx.maker_token
    END = mp.contract_address
AND mp.blockchain = 'ethereum'

{% if is_incremental() %}
AND mp.minute >= date_trunc('day', now() - interval '1 week')
{% endif %}
{% if not is_incremental() %}
AND mp.minute >= '{{zeroex_v3_start_date}}'
{% endif %}

LEFT OUTER JOIN {{ ref('tokens_ethereum_erc20') }} ts ON ts.contract_address = taker_token
LEFT OUTER JOIN {{ ref('tokens_ethereum_erc20') }} ms ON ms.contract_address = maker_token
