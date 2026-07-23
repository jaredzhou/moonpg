# MoonPG 项目申报书

**项目名称**：MoonPG — 纯 MoonBit PostgreSQL 客户端驱动程序
**参赛者**：jaredzhou　　　**联系方式**：18918321024
**GitHub**：https://github.com/jaredzhou/moonpg
**项目方向**：MoonBit 数据库驱动与网络协议　　　**是否移植**：是

MoonPG 将 PostgreSQL 原生客户端驱动移植到 MoonBit 生态，从 TCP 层开始完整实现 PostgreSQL v3 有线协议，零 C 依赖（无 libpq、无原生桩代码）。项目实现了完整的前后端消息编解码、三种认证方式（cleartext / MD5 / SCRAM-SHA-256）、TLS/SSL 安全传输、连接池（含健康检查与后台维护）、事务支持、COPY 批量导入协议、LISTEN/NOTIFY 异步通知、以及基于 trait 的多态类型编解码系统（ToValue / FromRaw + 泛型 Option[T] 可空列）。223 个测试覆盖所有公开 API 与有线协议路径。API 简洁、功能完整，零 C 依赖，适用于 MoonBit Web 后端开发、ETL 数据处理管道、微服务数据访问层、数据分析与报表系统、实时消息通知等场景。配合 FoxQL（编译期类型安全 SQL 构建器）与 QueryX（JSON 查询 DSL + FoxQL 桥接），moonpg 与二者形成完整的 MoonBit PostgreSQL 技术栈——驱动层、查询构建层、RESTful 过滤层各司其职，为 pony Web 框架提供从连接到接口的端到端 PostgreSQL 开发体验。

**核心功能范围**：

- **wire 子包（有线协议层）**：完整 PostgreSQL v3 协议实现
  - `raw_conn.mbt`（~1,500 行）：TCP 连接、SSL 协商、Startup 握手、认证状态机、消息收发帧、`simple_query` / `execute_params`（扩展查询协议）、`prepare` / `execute_prepared`、连接生命周期管理（lock/unlock/close）、Cancel 请求
  - `frontend_messages.mbt`（~740 行）：18 种客户端消息 — StartupMessage、Query、Parse、Bind、Execute、Describe、Close、Sync、PasswordMessage、SASLInitialResponse、SASLResponse、Terminate、Flush、CopyData/CopyDone/CopyFail、SSLRequest
  - `backend_messages.mbt`（~1,200 行）：20+ 种服务端消息 — RowDescription、DataRow、CommandComplete、ReadyForQuery、ErrorResponse、NoticeResponse、Authentication*（Ok/CleartextPassword/MD5Password/SASL/SASLContinue/SASLFinal）、BackendKeyData、ParameterStatus、ParseComplete/BindComplete/CloseComplete、NegotiateProtocolVersion 等
  - `result_reader.mbt`：拉取式结果集读取器，支持 `has_next()` + `data_row()` 流式消费与 `read()` 批量收集
- **认证**：`auth_md5.mbt`（MD5 加盐密码）、`auth_scram.mbt`（SCRAM-SHA-256，完整四步握手 + channel binding）
- **config.mbt**：连接字符串解析器，兼容 URI（`postgres://` / `postgresql://`）与 key=value 两种格式，支持 sslmode/sslrootcert/sslcert/sslkey/connect_timeout/statement_timeout/target_session_attrs 全部参数
- **transport.mbt**：Transport trait 抽象 TCP 与 TLS 连接，统一 `Reader + Writer` 接口
- **conn.mbt（公开 API）**：Connection、Rows trait（ConnRows / PoolRows）、QueryExecutor trait（query / query_one / execute）、Row / ExecResult、PgError 类型、Listener（LISTEN/NOTIFY 异步接收器）、CopyWriter（流式 COPY FROM STDIN）
- **pool.mbt（连接池）**：无界队列连接池，acquire/release、min_idle 预填充、max_idle_sec 闲置过期、max_lifetime_sec 连接寿命、health_check 检出前心跳、后台 maintenance 协程、PoolStats 统计
- **tx.mbt（事务）**：Tx trait（commit/rollback）、TxBeginner trait（begin_tx）、DbTx / PoolDbTx、begin_func 自动提交/回滚闭包模式、IsolationLevel / TxOptions（read_only/deferrable）
- **value.mbt（类型编解码）**：Value enum（Null/Bool/Int/Int64/Float/String/Bytes）、RawValue（带格式标记的原始字节）、ToValue trait（MoonBit 类型 → 参数）、FromRaw trait（结果单元 → MoonBit 类型）、int4/int8/float8/bool 二进制编解码、COPY 文本转义
- **types.mbt（类型实现）**：Int/Int64/Double/Bool/String/Bytes/Json/Decimal/UUID/Timestamp 的 ToValue + FromRaw 实现，Option[T] 泛型可空支持
- **测试**：223 用例（conn_test 38 + tx_test 25 + pool_test 38 + integration_test 27 + wire/raw_conn_test 58 + wire/config_test 28 + value 14 + types 6），黑白盒分离（`_test.mbt`），隔离表名保证独立执行
- **CI/CD**：GitHub Actions 完整流水线（fmt --check → moon info → check --deny-warn → test --deny-warn），PostgreSQL 16 服务容器

**移植参考说明**：
原项目：pgx　|　https://github.com/jackc/pgx
原项目许可证：MIT　　本项目许可证：Apache 2.0

与 Go 原版（pgx）的简化与重新设计：

- 有线协议从零以纯 MoonBit 实现 — 不依赖 libpq 或任何 C 库，基于 `moonbitlang/async` 协程运行时与 `@socket.Tcp` / `@async.tls` 构建 TCP/TLS 传输层
- API 设计遵循 pgx 风格（`QueryExecutor` trait、`Rows` 拉取式迭代、`ToValue`/`FromRaw` 类型系统），但不照搬内部结构 — MoonBit 的模式匹配、枚举、trait 系统重新组织了消息编解码与类型转换路径
- 连接池以 `@aqueue.Queue`（无界异步队列）+ `Ref[Int]` 原子计数实现，替代 Go 的 channel + mutex 模式，适合 MoonBit 单线程协作式调度
- 扩展查询协议（Parse→Bind→Describe→Execute→Sync）完整实现，参数化查询以 MoonBit 泛型 `Array[&ToValue]` 传递，格式码自动推导
- 认证层以 MoonBit 模式匹配重写 SCRAM-SHA-256 状态机（client-first → server-first → client-final → server-final），`@x/crypto` + `@x/codec/base64` 替代 Go 标准库 crypto
- 后续扩展：pgx 的 batch 模式（多语句管线化）、逻辑复制协议、COPY TO STDOUT；暂不实现 pgx 的 hstore/array/range 等 PG 特有类型、数据库/schema 内省、连接字符串密码文件读取
