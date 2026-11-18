#!/usr/bin/env bash
# 验收回放：并发位置更新 / 分区提交中断 / 截关后更正 / 承运人回执差异
# 前置：服务已启动（本地 mvn spring-boot:run 或 docker compose up）
# 用法：./scripts/replay-acceptance.sh   （可用 BASE_URL 覆盖服务地址）
set -uo pipefail

BASE=${BASE_URL:-http://127.0.0.1:8080}
INGEST="ingest:ingest123"
DISPATCH="dispatcher:disp123"
SETTLE="settlement:settle123"
ADMIN="admin:admin123"
VOYAGE="V2026-11A"
CUTOFF="2026-11-20T18:00:00+08:00"

PASS=0; FAIL=0
check() { # check <描述> <实际> <期望>
  if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); echo "  ✔ $1（=$2）";
  else FAIL=$((FAIL+1)); echo "  ✘ $1：期望[$3] 实际[$2]"; fi
}

api() { # api <user:pass> <METHOD> <path> [json-body] → stdout=body
  local auth=$1 method=$2 path=$3 body=${4:-}
  if [[ -n "$body" ]]; then
    curl -sS -u "$auth" -X "$method" "$BASE$path" -H 'Content-Type: application/json' -d "$body"
  else
    curl -sS -u "$auth" -X "$method" "$BASE$path"
  fi
}

api_status() { # api_status <user:pass> <METHOD> <path> [json-body] → stdout=http_code, body落盘 /tmp/replay_body.json
  local auth=$1 method=$2 path=$3 body=${4:-}
  if [[ -n "$body" ]]; then
    curl -sS -o /tmp/replay_body.json -w "%{http_code}" -u "$auth" -X "$method" "$BASE$path" -H 'Content-Type: application/json' -d "$body"
  else
    curl -sS -o /tmp/replay_body.json -w "%{http_code}" -u "$auth" -X "$method" "$BASE$path"
  fi
}

echo "== 0. 等待服务并就绪重置 =="
for i in $(seq 1 30); do
  if curl -sS -o /dev/null "$BASE/v3/api-docs" 2>/dev/null; then break; fi
  sleep 1
done
curl -sS -o /dev/null "$BASE/v3/api-docs" || { echo "服务不可达: $BASE"; exit 1; }
api "$ADMIN" POST /api/dev/reset > /dev/null
echo "  服务可达，业务表已重置"

echo "== 1. 登记航次订舱（$VOYAGE，6 箱）=="
BOOKINGS=$(cat "$(dirname "$0")/../src/main/resources/samples/bookings.json")
api "$SETTLE" POST /api/manifests/bookings "$BOOKINGS" > /dev/null
echo "  订舱完成"

echo "== 2. 回放本地事件样例（先装船后场桥，模拟乱序入库）=="
for s in gate-events vessel-events crane-events yard-events; do
  N=$(api "$INGEST" POST "/api/ingest/replay/$s" | jq 'length')
  echo "  回放 $s: $N 条"
done

echo "== 3. 场景B-1：分区提交未完成时冻结清单 → 必须失败且不发布任何数据 =="
CODE=$(api_status "$SETTLE" POST /api/manifests/freeze "{\"voyageNo\":\"$VOYAGE\",\"cutoffTime\":\"$CUTOFF\"}")
check "冻结被拒绝(HTTP 409)" "$CODE" "409"
check "失败原因=存在未提交事件" "$(jq -r '.message | contains("尚未提交")' /tmp/replay_body.json)" "true"
check "清单表仍为空" "$(api "$SETTLE" GET "/api/manifests?voyageNo=$VOYAGE" | jq 'length')" "0"

echo "== 4. 生成湖仓提交（不可变提交，按箱号+作业分区）=="
api "$INGEST" POST /api/commits/generate-all > /tmp/gen.json
check "全部箱号已处理" "$(jq 'length' /tmp/gen.json)" "6"

echo "== 5. 场景A：并发位置更新 —— 冲突进待裁定，不由最后写入者决定 =="
check "待裁定冲突数" "$(api "$DISPATCH" GET '/api/commits/conflicts?status=PENDING' | jq 'length')" "1"
check "冲突原因" "$(api "$DISPATCH" GET '/api/commits/conflicts?status=PENDING' | jq -r '.[0].reason')" "BIZ_TIME_TIE"
check "冲突箱号" "$(api "$DISPATCH" GET '/api/commits/conflicts?status=PENDING' | jq -r '.[0].containerNo')" "CNU0002"
V3=$(api "$DISPATCH" GET /api/dispatch/containers/CNU0003)
check "CNU0003 后入库的场桥报文未覆盖装船确认(loaded)" "$(echo "$V3" | jq -r '.currentState.loaded')" "true"
check "CNU0003 当前位置在船上" "$(echo "$V3" | jq -r '.currentState.position')" "VESSEL:V2026-11A"
V2=$(api "$DISPATCH" GET /api/dispatch/containers/CNU0002)
check "CNU0002 冲突未裁定前 loaded 未定" "$(echo "$V2" | jq -r '.currentState.loaded')" "false"
check "CNU0002 待裁定事件数" "$(echo "$V2" | jq -r '.pendingArbitrationCount')" "2"

echo "== 6. 场景B-2：存在待裁定冲突时冻结清单 → 必须失败（不用半个分区发布航次）=="
CODE=$(api_status "$SETTLE" POST /api/manifests/freeze "{\"voyageNo\":\"$VOYAGE\",\"cutoffTime\":\"$CUTOFF\"}")
check "冻结被拒绝(HTTP 409)" "$CODE" "409"
check "失败原因=存在待裁定" "$(jq -r '.message | contains("待裁定")' /tmp/replay_body.json)" "true"
check "清单表仍为空" "$(api "$SETTLE" GET "/api/manifests?voyageNo=$VOYAGE" | jq 'length')" "0"

echo "== 7. 调度裁定冲突：装船确认有效，场桥迟到重复报文被取代 =="
CONFLICT_ID=$(api "$DISPATCH" GET '/api/commits/conflicts?status=PENDING' | jq '.[0].id')
WINNER=$(api "$DISPATCH" GET '/api/ingest/events?containerNo=CNU0002&status=PENDING_ARBITRATION' \
  | jq '[.[] | select(.eventType=="LOAD_CONFIRM")][0].id')
api "$DISPATCH" POST "/api/commits/conflicts/$CONFLICT_ID/resolve" \
  "{\"winnerEventId\":$WINNER,\"note\":\"场桥14:00报文为迟到重复上报，装船确认有效\"}" > /dev/null
V2=$(api "$DISPATCH" GET /api/dispatch/containers/CNU0002)
check "裁定后 CNU0002 已装船" "$(echo "$V2" | jq -r '.currentState.loaded')" "true"
check "被取代报文仍可溯源" "$(api "$DISPATCH" GET /api/dispatch/containers/CNU0002/lineage | jq '[.[] | select(.status=="SUPERSEDED")] | length')" "1"

echo "== 8. 冻结截关快照（截关 $CUTOFF）=="
api "$SETTLE" POST /api/manifests/freeze "{\"voyageNo\":\"$VOYAGE\",\"cutoffTime\":\"$CUTOFF\"}" > /tmp/freeze.json
check "清单状态" "$(jq -r '.status' /tmp/freeze.json)" "FROZEN"
check "清单行数" "$(jq '.itemCount' /tmp/freeze.json)" "6"
check "完整提交边界(6箱×3分区)" "$(jq '.commitFrontier | length' /tmp/freeze.json)" "18"
MID=$(jq '.manifestId' /tmp/freeze.json)
check "CNU0005 快照移箱次数=2（更正前）" \
  "$(api "$SETTLE" GET "/api/manifests/$MID/items" | jq '[.[] | select(.containerNo=="CNU0005")][0].moveCount')" "2"

echo "== 9. 场景C：截关后更正 → 修订候选 → 费用调整单；原始结算不改写 =="
api "$INGEST" POST /api/ingest/replay/correction-events > /dev/null
api "$INGEST" POST /api/commits/generate-all > /dev/null
CAND=$(api "$SETTLE" GET "/api/revisions?manifestId=$MID")
check "修订候选数" "$(echo "$CAND" | jq 'length')" "1"
check "候选差异说明" "$(echo "$CAND" | jq -r '.[0].diffSummary | contains("moveCount: 2 → 3")')" "true"
check "冻结清单行未被改写(仍=2)" \
  "$(api "$SETTLE" GET "/api/manifests/$MID/items" | jq '[.[] | select(.containerNo=="CNU0005")][0].moveCount')" "2"
check "调度当前视图已反映更正(=3)" \
  "$(api "$DISPATCH" GET /api/dispatch/containers/CNU0005 | jq '.currentState.moveCount')" "3"
CAND_ID=$(echo "$CAND" | jq '.[0].id')
ADJ=$(api "$SETTLE" POST "/api/revisions/$CAND_ID/decide" '{"accept":true,"note":"盘点确认漏报一次移箱"}')
check "接受候选生成调整单数" "$(echo "$ADJ" | jq '.feeAdjustmentIds | length')" "1"

echo "== 10. 场景D：承运人回执差异对账 =="
api "$SETTLE" POST /api/recon/receipts/replay/carrier-receipts > /dev/null
RUN=$(api "$SETTLE" POST "/api/recon/compare?manifestId=$MID")
RUN_ID=$(echo "$RUN" | jq '.runId')
check "回执匹配箱数" "$(echo "$RUN" | jq '.summary.matched')" "4"
DIFFS=$(api "$SETTLE" GET "/api/recon/runs/$RUN_ID" | jq '.diffs')
check "CNU0004 装船事实差异" "$(echo "$DIFFS" | jq '[.[] | select(.diffType=="LOADED_MISMATCH")] | length')" "1"
check "CNU0004 费用差异" "$(echo "$DIFFS" | jq '[.[] | select(.diffType=="FEE_MISMATCH")] | length')" "1"
check "CNU0006 回执缺失" "$(echo "$DIFFS" | jq '[.[] | select(.diffType=="MISSING_ON_RECEIPT")] | length')" "1"
LOADED_DIFF_ID=$(echo "$DIFFS" | jq '[.[] | select(.diffType=="LOADED_MISMATCH")][0].id')
FEE_DIFF_ID=$(echo "$DIFFS" | jq '[.[] | select(.diffType=="FEE_MISMATCH")][0].id')
MISS_DIFF_ID=$(echo "$DIFFS" | jq '[.[] | select(.diffType=="MISSING_ON_RECEIPT")][0].id')
ADJ2=$(api "$SETTLE" POST "/api/recon/diffs/$LOADED_DIFF_ID/adjust" '{"note":"快照为已装船，向承运人补收装船费"}')
check "装船差异调整金额(+450)" "$(echo "$ADJ2" | jq '.deltaAmount == 450')" "true"
api "$SETTLE" POST "/api/recon/diffs/$FEE_DIFF_ID/ignore" '{"note":"已被LOADED_MISMATCH调整覆盖"}' > /dev/null
api "$SETTLE" POST "/api/recon/diffs/$MISS_DIFF_ID/ignore" '{"note":"承运人系统延迟，下周补回执"}' > /dev/null
check "差异处理完成(OPEN=0)" "$(api "$SETTLE" GET '/api/recon/diffs?status=OPEN' | jq 'length')" "0"

echo "== 11. 结算视图：只能引用已冻结版本；调整单与原始结算分列 =="
CHARGES=$(api "$SETTLE" GET "/api/settlement/manifests/$MID/charges")
check "原始结算合计(6箱=3260)" "$(echo "$CHARGES" | jq '.originalTotal == 3260')" "true"
check "调整单合计(80更正+450对账=530)" "$(echo "$CHARGES" | jq '.adjustmentTotal == 530')" "true"
check "结算总额(=3790)" "$(echo "$CHARGES" | jq '.settledTotal == 3790')" "true"
check "调整单可解释(含依据)" \
  "$(api "$SETTLE" GET "/api/settlement/manifests/$MID/adjustments" | jq '[.[] | select(.basis != null)] | length')" "2"
CODE=$(api_status "$SETTLE" GET "/api/settlement/quote?voyageNo=$VOYAGE")
check "绕过冻结清单直接结算被拒绝(HTTP 400)" "$CODE" "400"

echo ""
echo "=========================================="
echo "验收回放完成：通过 $PASS 项，失败 $FAIL 项"
echo "=========================================="
[[ $FAIL -eq 0 ]]
