#!/bin/bash
# Initialize the memory directory structure

MEMORY_DIR="$HOME/.aria-memory"

mkdir -p "$MEMORY_DIR"/{knowledge,impressions/archived}

# Create index.md if not exists
if [ ! -f "$MEMORY_DIR/index.md" ]; then
  cat > "$MEMORY_DIR/index.md" << 'EOF'
# 随身索引

## 关于用户
<!-- 用户身份、偏好、技能等（~30条） -->

## 活跃话题
<!-- 当前关注的项目、技术、问题等（~50条） -->

## 重要提醒
<!-- 带时间限定的提醒事项（~20条） -->

## 近期上下文
<!-- 最近对话中的关键信息（~50条） -->

## 备用
<!-- 降级候选，仍有价值但优先级较低（~50条） -->
EOF
fi

# Create meta.json if not exists
if [ ! -f "$MEMORY_DIR/meta.json" ]; then
  cat > "$MEMORY_DIR/meta.json" << 'EOF'
{
  "indexVersion": 0,
  "totalImpressions": 0,
  "totalKnowledgeFiles": 0,
  "pendingWrapups": [],
  "compactionEvents": [],
  "lastGlobalSleepAt": null
}
EOF
fi

# Create personality.md if not exists
if [ ! -f "$MEMORY_DIR/personality.md" ]; then
  echo "# 用户交互风格" > "$MEMORY_DIR/personality.md"
  echo "" >> "$MEMORY_DIR/personality.md"
  echo "（尚无足够数据，待 global_sleep 分析后自动生成）" >> "$MEMORY_DIR/personality.md"
fi
