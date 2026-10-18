#ifndef SQLITE_BUDGET_H
#define SQLITE_BUDGET_H

#include <sqlite3.h>

/// The name of the write-budget VFS: the default VFS with every method delegated unchanged, except that while a budget
/// is armed for a database, each write that extends one of its files (the database, its WAL or its rollback journal)
/// is first charged against that budget and refused with SQLITE_FULL, before anything is written, when it does not fit.
/// Growth between checks is therefore at most one write: one page or one WAL frame.
///
/// Accounting: a WAL frame written while armed is charged for any growth of the WAL and for the copy a checkpoint later
/// makes of it into the database file, which it reserves. The reservation outlives the arm (and the connection): a
/// checkpoint's extension of the database file pays it, armed or not, never charged again; a WAL that starts again
/// (every frame copied) releases it; each new arm counts what is still reserved as spent. A WAL that survived the last
/// process (killed before a checkpoint) is reserved in full when it is first opened again. Extending truncations and
/// size hints are charged before they happen too, as the whole chunks the system allocates for them. A COMMIT that succeeded stays committed whatever a later checkpoint
/// finds.
#define NTP_BUDGET_VFS "ntp-budget"

#ifdef __cplusplus
extern "C" {
#endif

/// Registers the VFS (once; later calls do nothing). Returns SQLITE_OK.
int ntp_budget_register(void);

/// Arms `budget` bytes for the database `schema` ("main") of `db` and every connection to the same file; checkpoint
/// copies still reserved by earlier arms count as already charged.
/// Returns SQLITE_MISUSE when that database was not opened through the VFS.
int ntp_budget_arm(sqlite3 *db, const char *schema, sqlite3_int64 budget);

/// Ends the armed budget (writes are no longer charged).
int ntp_budget_disarm(sqlite3 *db, const char *schema);

typedef struct ntp_budget_state {
    sqlite3_int64 budget;
    /// Bytes charged since the budget was armed (reserved checkpoint copies included).
    sqlite3_int64 charged;
    /// The reserve of WAL copies not yet paid by a checkpoint.
    sqlite3_int64 reserved;
    /// A write was refused since arming, and what it would have cost.
    int refused;
    sqlite3_int64 refused_charge;
    int armed;
} ntp_budget_state;

/// The database's budget now.
int ntp_budget_read(sqlite3 *db, const char *schema, ntp_budget_state *state);

#ifdef __cplusplus
}
#endif

#endif
