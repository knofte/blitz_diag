# Blitz Diag

🧠 A no-nonsense diagnostics tool for **MySQL**, **MariaDB**, and **Percona Server**.

`blitz_diag` runs a lightweight, comprehensive server check and stores the results in a single, easy-to-read table.

---

## 🚀 What It Checks

| Check                          | ID   | Purpose                                                                 |
|-------------------------------|------|-------------------------------------------------------------------------|
| Query Cache                   | #01 | Detects whether query cache is enabled (should usually be off)         |
| InnoDB Buffer Pool            | #02 | Evaluates buffer pool read efficiency                                   |
| Temp Tables                   | #03 | Flags high usage of disk-based temporary tables                         |
| Missing Primary Keys          | #04 | Finds tables without primary keys (bad for indexing and replication)   |
| MyISAM Tables                 | #05 | Identifies tables still using the legacy MyISAM engine                  |
| Foreign Key Mismatches        | #06 | Detects mismatches in FK column types between referencing tables        |
| Summary                       | —    | Heuristics summary with emoji indicators (✅ / ⚠️)                        |

---

## 🛠️ Installation

1. Clone/download the repo
2. Connect to your server using MySQL CLI or Adminer/phpMyAdmin/etc
3. Run:
   ```sql
   SOURCE blitz_base_diag.sql;

This will:

    Create a schema: blitz_diag42

    Create a procedure: blitz_diag()

    Create a table: blitz_output

✅ Usage

To run the diagnostics:

CALL blitz_diag();

To view results:

SELECT * FROM blitz_diag42.blitz_output ORDER BY section_order;

💡 Notes

    Read-only: This script does **not** modify your data.

    Designed for quick insights during audits or debugging.

    Works on MySQL 5.7+, MariaDB 10.2+, and Percona.

📘 Coming Soon

    Optional verbose/quiet modes

    Scheduled reporting or webhook integrations

    Web doc per check: blitz_diag.io#04 → explain "Missing Primary Key", etc.

📄 License

MIT — use, fork, enhance as you like.
✨ Maintained by

Built with ❤️ by the community. Originally started by Kent Riboe — feel free to PR.

