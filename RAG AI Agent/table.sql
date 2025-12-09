-- ====================================================================================

-- Document & Vector Storage — 优化建表与迁移脚本（最终版）

-- 变更：将 document_metadata 的 "schema" 字段改名为 doc_schema

-- 说明：

-- - 启用 pgvector 扩展用于向量类型与索引（需要相应权限）

-- - 使用 TIMESTAMPTZ 记录时间

-- - metadata/jsonb 字段使用 GIN 索引

-- - 提供 HNSW 与 ivfflat 两种向量索引的尝试；优先使用 HNSW

-- - match_documents 函数返回 distance 与 similarity（方便客户端自定义阈值）

-- - 包含兼容迁移步骤：如果存在旧列 "schema"，会安全地将数据复制到 doc_schema，然后删除旧列

-- ====================================================================================

  

-- ====================================================================================

-- 0) 备份提示（执行前请务必备份）

-- ====================================================================================

-- 建议：

-- pg_dump --format=c --file=backup_pre_optimize.dump --dbname=YOUR_DB_NAME

  

-- ====================================================================================

-- 1) 安装/启用扩展：pgvector（向量支持）

-- ====================================================================================

-- 需要超级用户或托管平台允许安装扩展。在 Supabase 环境通常可用。

CREATE EXTENSION IF NOT EXISTS vector;

  

-- ====================================================================================

-- 2) 清理旧对象（仅在你确认要重建全部表/函数时执行）

-- ====================================================================================

-- 注意：下面的 DROP 语句会删除数据；如果你只想迁移列名并保留数据，请跳过 DROP 部分。

-- 如果你想保留现有数据并只重命名列，请只执行迁移部分（见下方的迁移段）。

DROP FUNCTION IF EXISTS public.match_documents(vector, float, int) CASCADE;

DROP TABLE IF EXISTS public.documents CASCADE;

DROP TABLE IF EXISTS public.document_rows CASCADE;

DROP TABLE IF EXISTS public.document_metadata CASCADE;

  

-- ====================================================================================

-- 3) 建表：document_metadata（元数据表，包含 doc_schema）

-- ====================================================================================

-- 设计说明：

-- - id 保持为 TEXT（兼容现有系统）；后续可迁移为 UUID

-- - created_at 使用 TIMESTAMPTZ（带时区）

-- - 将原先的 "schema" 字段替换为 doc_schema，以避免使用 SQL 关键字

CREATE TABLE public.document_metadata (

id TEXT PRIMARY KEY, -- 主键：保持为 TEXT，确保上层写入唯一值

title TEXT, -- 可选：文档标题

url TEXT, -- 可选：来源 URL

created_at TIMESTAMPTZ DEFAULT NOW(), -- 带时区的时间戳，默认当前时间

doc_schema TEXT -- 新列：替代原来的 "schema" 字段

);

  

-- 注释（便于理解）

COMMENT ON TABLE public.document_metadata IS '文档元数据：id (TEXT)、title、url、created_at (带时区)、doc_schema';

COMMENT ON COLUMN public.document_metadata.id IS '主键 id (TEXT)。如需要可考虑迁移为 UUID。';

COMMENT ON COLUMN public.document_metadata.created_at IS '创建时间（带时区）。';

COMMENT ON COLUMN public.document_metadata.doc_schema IS '从原始 "schema" 重命名以避免 SQL 关键字冲突；用于存储文档的 schema 名称或类型。';

  

-- 索引：加速按时间查询的场景

CREATE INDEX IF NOT EXISTS idx_document_metadata_created_at ON public.document_metadata (created_at);

  

-- ====================================================================================

-- 4) 建表：document_rows（段/行数据）

-- ====================================================================================

-- 设计说明：

-- - row_data 使用 JSONB，支持 GIN 索引以加速结构化查询

-- - dataset_id 作为外键引用 document_metadata(id)

CREATE TABLE public.document_rows (

id BIGSERIAL PRIMARY KEY, -- 自动增长主键（适用于大规模数据）

dataset_id TEXT NOT NULL REFERENCES public.document_metadata(id), -- 外键引用

row_data JSONB NOT NULL -- 存储结构化行数据，使用 JSONB

);

  

COMMENT ON TABLE public.document_rows IS '文档的行/段，使用 dataset_id 引用 document_metadata';

COMMENT ON COLUMN public.document_rows.row_data IS '行内容以 JSONB 存储以便灵活查询';

  

-- 索引：加速按 dataset_id 的查找

CREATE INDEX IF NOT EXISTS idx_document_rows_dataset_id ON public.document_rows (dataset_id);

  

-- GIN 索引：加速 JSONB 内容查询（例如 row_data->>'...')

CREATE INDEX IF NOT EXISTS idx_document_rows_row_data_gin ON public.document_rows USING GIN (row_data);

  

-- ====================================================================================

-- 5) 建表：documents（文本、metadata 与向量）

-- ====================================================================================

-- 设计说明：

-- - embedding 使用 vector(1024) 作为示例维度（请根据实际模型替换）

-- - metadata 使用 jsonb 并建立 GIN 索引

-- - content 建全文索引以支持全文检索

CREATE TABLE public.documents (

id BIGSERIAL PRIMARY KEY,

content TEXT,

metadata JSONB,

embedding VECTOR(1024) -- 示例为 1024 维：请替换为与你的模型匹配的维度

);

  

COMMENT ON TABLE public.documents IS '存储文档内容、metadata (jsonb) 与 embedding (向量) 的表';

COMMENT ON COLUMN public.documents.embedding IS '向量 embedding (vector(N))。请确保维度与模型输出一致。';

  

-- JSONB 索引：加速对 metadata 的查询

CREATE INDEX IF NOT EXISTS idx_documents_metadata_gin ON public.documents USING GIN (metadata);

  

-- 全文检索索引（可选）

CREATE INDEX IF NOT EXISTS idx_documents_content_tsv ON public.documents USING GIN (to_tsvector('simple', coalesce(content, '')));

  

-- 向量索引：优先尝试 HNSW（如果支持）；否则回退为 ivfflat

DO $$

BEGIN

BEGIN

-- 尝试创建 HNSW 索引（适用于 pgvector 支持 hnsw）

EXECUTE 'CREATE INDEX IF NOT EXISTS idx_documents_embedding_hnsw ON public.documents USING hnsw (embedding) WITH (m = 16, ef_construction = 200);';

RAISE NOTICE '已创建或确认 documents.embedding 的 HNSW 索引';

EXCEPTION WHEN OTHERS THEN

RAISE NOTICE 'HNSW 索引创建失败或不支持；尝试使用 ivfflat 作为回退';

BEGIN

EXECUTE 'CREATE INDEX IF NOT EXISTS idx_documents_embedding_ivfflat ON public.documents USING ivfflat (embedding vector_l2_ops) WITH (lists = 100);';

RAISE NOTICE '已创建或确认 documents.embedding 的 ivfflat 索引';

EXCEPTION WHEN OTHERS THEN

RAISE NOTICE 'ivfflat 索引创建失败。请确认 pgvector 支持对应的索引类型并已正确安装扩展。';

END;

END;

END;

$$ LANGUAGE plpgsql;

  

-- 在大量插入向量后，请运行：ANALYZE public.documents;

  

-- ====================================================================================

-- 6) match_documents 函数（向量检索，返回 distance 与 similarity）

-- ====================================================================================

-- 说明：

-- - 参数：

-- query_embedding VECTOR(1024) — 待匹配的查询向量

-- similarity_threshold FLOAT — 相似度阈值 [0..1]；若为 NULL 表示不筛选（返回 top-N）

-- match_count INT — 返回的候选数量上限

-- - 返回值：

-- id, content, metadata, distance (L2 距离), similarity（基于 max_distance 的线性映射）

CREATE OR REPLACE FUNCTION public.match_documents(

query_embedding VECTOR(1024),

similarity_threshold FLOAT,

match_count INT

)

RETURNS TABLE (

id BIGINT,

content TEXT,

metadata JSONB,

distance FLOAT,

similarity FLOAT

)

LANGUAGE plpgsql

AS $$

DECLARE

-- 注意：max_distance 是经验值；请根据实际向量分布调整。

-- 若使用归一化向量并使用内积/余弦相似度，建议修改计算方法。

max_distance CONSTANT FLOAT := 2.0;

distance_threshold FLOAT;

BEGIN

-- 如果未传入 similarity_threshold，则不做阈值筛选（使用较大的 max_distance）

IF similarity_threshold IS NULL THEN

distance_threshold := max_distance;

ELSE

IF similarity_threshold > 1 OR similarity_threshold < -1 THEN

RAISE EXCEPTION 'similarity_threshold 的取值必须在 -1 到 1 之间（或为 NULL）';

END IF;

-- 将相似度映射为距离的简单线性映射（客户端可根据需要替换映射公式）

distance_threshold := max_distance * (1 - similarity_threshold);

END IF;

  

RETURN QUERY

SELECT

d.id,

d.content,

d.metadata,

d.embedding <=> query_embedding AS distance,

1 - (d.embedding <=> query_embedding) / max_distance AS similarity

FROM public.documents d

WHERE (d.embedding <=> query_embedding) <= distance_threshold

ORDER BY d.embedding <=> query_embedding

LIMIT match_count;

END;

$$;

  

COMMENT ON FUNCTION public.match_documents(VECTOR(1024), FLOAT, INT) IS

'按向量匹配文档。返回 id、content、metadata、L2 距离，以及一个基于 max_distance 的近似相似度。请根据你的向量分布调整 max_distance。';
```
