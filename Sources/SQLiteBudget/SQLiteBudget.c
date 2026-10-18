#include "SQLiteBudget.h"

#include <pthread.h>
#include <stdlib.h>
#include <string.h>

/* One database file and the files that belong to it (its WAL and rollback journal), across connections. */
typedef struct BudgetGroup {
    char *name;
    int refs;
    int armed;
    sqlite3_int64 budget;
    sqlite3_int64 charged;
    sqlite3_int64 reserved;
    int refused;
    sqlite3_int64 refusedCharge;
    /* A WAL of this database was opened in this group's lifetime. */
    int walSeen;
    struct BudgetGroup *next;
} BudgetGroup;

enum { KindDatabase = 0, KindWAL = 1, KindJournal = 2 };

typedef struct BudgetFile {
    sqlite3_file base;
    sqlite3_file *real;
    BudgetGroup *group; /* NULL: not charged (temporary and statement files) */
    int kind;
    sqlite3_int64 size;
    /* The chunk size set (0: none): a truncation or a size hint then allocates whole chunks. */
    sqlite3_int64 chunk;
} BudgetFile;

static pthread_mutex_t budgetLock = PTHREAD_MUTEX_INITIALIZER;
static BudgetGroup *groups = NULL;
static sqlite3_vfs budgetVfs;
static sqlite3_vfs *realVfs = NULL;

/* The file system this one delegates to: the default at the time of the call (another pass-through file system made
   default, a test's observer, sits below this one), or the default it was registered over. */
static sqlite3_vfs *innerVfs(void) {
    sqlite3_vfs *current = sqlite3_vfs_find(NULL);
    return current && current != &budgetVfs ? current : realVfs;
}
static int registered = 0;

#define REAL(file) (((BudgetFile *)(file))->real)

static BudgetGroup *groupRetain(const char *name) {
    for (BudgetGroup *group = groups; group; group = group->next) {
        if (strcmp(group->name, name) == 0) { group->refs++; return group; }
    }
    BudgetGroup *group = calloc(1, sizeof(BudgetGroup));
    if (!group) return NULL;
    group->name = strdup(name);
    if (!group->name) { free(group); return NULL; }
    group->refs = 1;
    group->next = groups;
    groups = group;
    return group;
}

static void groupRelease(BudgetGroup *group) {
    if (!group || --group->refs > 0) return;
    for (BudgetGroup **link = &groups; *link; link = &(*link)->next) {
        if (*link == group) { *link = group->next; break; }
    }
    free(group->name);
    free(group);
}

/* What extending `file` by `extension` bytes, writing `written` bytes of WAL frames, costs; applied to the group if it
   fits. Returns 0 when refused (nothing applied). Called under the lock.
   Every WAL frame written while armed (appended, or written over space the WAL already had) reserves the copy a
   checkpoint later makes of it into the database file, and is charged for it as well as for any growth. The
   reservation lives in the group, across arms and connections, until a checkpoint's extension of the database file
   pays it (armed or not) or the WAL starts again (every frame copied). Each arm counts the reservations still
   outstanding as already spent. */
static int charge(BudgetFile *file, sqlite3_int64 extension, sqlite3_int64 written) {
    BudgetGroup *group = file->group;
    if (!group) return 1;
    if (extension < 0) extension = 0;
    sqlite3_int64 cost = extension, reserve = 0, paid = 0;
    switch (file->kind) {
    case KindWAL:
        cost = extension + written;
        reserve = written;
        break;
    case KindDatabase:
        paid = extension < group->reserved ? extension : group->reserved;
        cost = extension - paid;
        break;
    default:
        break;
    }
    if (!group->armed) {
        /* Nothing is charged, but a checkpoint's copy still pays what was reserved for it. */
        group->reserved -= paid;
        return 1;
    }
    if (cost == 0 && reserve == 0 && paid == 0) return 1;
    if (group->charged + cost > group->budget) {
        group->refused = 1;
        group->refusedCharge = cost;
        return 0;
    }
    group->charged += cost;
    group->reserved += reserve - paid;
    return 1;
}

/* Growth that already happened (SQLite or the system extended the file by itself): taken whether or not it fits. */
static void chargeTaken(BudgetFile *file, sqlite3_int64 extension) {
    BudgetGroup *group = file->group;
    if (!group || extension <= 0) return;
    if (!charge(file, extension, 0)) group->charged += extension;
}

/* The WAL starts again (its header rewritten at offset 0, or the file truncated to nothing): every frame was copied,
   so nothing is owed for them any more. Called under the lock. */
static void releaseReservations(BudgetFile *file) {
    BudgetGroup *group = file->group;
    if (!group || file->kind != KindWAL) return;
    if (group->armed) group->charged -= group->reserved;
    if (group->charged < 0) group->charged = 0;
    group->reserved = 0;
}

/* What the system allocates for a request of `size` bytes: whole chunks when a chunk size is set. */
static sqlite3_int64 allocated(BudgetFile *file, sqlite3_int64 size) {
    if (file->chunk <= 0) return size;
    return ((size + file->chunk - 1) / file->chunk) * file->chunk;
}

/* MARK: - I/O methods: delegated unchanged, writes and truncation tracked. */

static int budgetClose(sqlite3_file *file) {
    BudgetFile *p = (BudgetFile *)file;
    int rc = p->real && p->real->pMethods ? p->real->pMethods->xClose(p->real) : SQLITE_OK;
    sqlite3_free(p->real);
    p->real = NULL;
    pthread_mutex_lock(&budgetLock);
    groupRelease(p->group);
    p->group = NULL;
    pthread_mutex_unlock(&budgetLock);
    return rc;
}

static int budgetRead(sqlite3_file *file, void *buffer, int amount, sqlite3_int64 offset) {
    return REAL(file)->pMethods->xRead(REAL(file), buffer, amount, offset);
}

static int budgetWrite(sqlite3_file *file, const void *buffer, int amount, sqlite3_int64 offset) {
    BudgetFile *p = (BudgetFile *)file;
    sqlite3_int64 end = offset + amount;
    if (p->group) {
        pthread_mutex_lock(&budgetLock);
        if (offset == 0) releaseReservations(p);
        sqlite3_int64 written = p->kind == KindWAL ? amount : 0;
        int fits = (end <= p->size && written == 0) || charge(p, end - p->size, written);
        /* Charged now, so a concurrent writer of the same file is not charged for the same bytes. */
        if (fits && end > p->size) p->size = end;
        pthread_mutex_unlock(&budgetLock);
        if (!fits) return SQLITE_FULL;
    }
    return p->real->pMethods->xWrite(p->real, buffer, amount, offset);
}

/* A truncation that would extend the file is charged first, and refused when it does not fit. */
static int budgetTruncate(sqlite3_file *file, sqlite3_int64 size) {
    BudgetFile *p = (BudgetFile *)file;
    sqlite3_int64 before = 0;
    if (p->group) {
        pthread_mutex_lock(&budgetLock);
        before = p->size;
        /* What the system will really allocate (rounded up to a chunk), charged before anything is passed on. */
        sqlite3_int64 target = allocated(p, size);
        int fits = target <= p->size || charge(p, target - p->size, 0);
        if (fits && target > p->size) p->size = target;
        pthread_mutex_unlock(&budgetLock);
        if (!fits) return SQLITE_FULL;
    }
    int rc = p->real->pMethods->xTruncate(p->real, size);
    if (p->group) {
        sqlite3_int64 actual = size;
        if (p->real->pMethods->xFileSize(p->real, &actual) != SQLITE_OK) actual = size;
        pthread_mutex_lock(&budgetLock);
        sqlite3_int64 counted = p->size > before ? p->size : before;
        /* Grown past what was charged anyway: the extra is taken. */
        if (actual > counted) chargeTaken(p, actual - counted);
        if (rc == SQLITE_OK) {
            p->size = actual;
            if (actual == 0) releaseReservations(p);
        }
        pthread_mutex_unlock(&budgetLock);
    }
    return rc;
}

static int budgetSync(sqlite3_file *file, int flags) { return REAL(file)->pMethods->xSync(REAL(file), flags); }

static int budgetFileSize(sqlite3_file *file, sqlite3_int64 *size) {
    return REAL(file)->pMethods->xFileSize(REAL(file), size);
}

static int budgetLockFile(sqlite3_file *file, int level) { return REAL(file)->pMethods->xLock(REAL(file), level); }
static int budgetUnlock(sqlite3_file *file, int level) { return REAL(file)->pMethods->xUnlock(REAL(file), level); }
static int budgetCheckReserved(sqlite3_file *file, int *out) { return REAL(file)->pMethods->xCheckReservedLock(REAL(file), out); }

static int budgetFileControl(sqlite3_file *file, int op, void *argument) {
    BudgetFile *p = (BudgetFile *)file;
    /* A size hint may preallocate: charged first, and not passed on when it does not fit (SQLite treats a hint's
       failure as no hint; each later write is then charged on its own). */
    sqlite3_int64 hinted = -1, before = 0;
    /* Without a chunk size a hint allocates nothing (a checkpoint hints the database's final size before copying):
       nothing is charged or paid for it; the copies pay as they extend the file. */
    if (op == SQLITE_FCNTL_SIZE_HINT && p->group && argument && p->chunk > 0) {
        /* The whole chunks it allocates are charged before it is passed on. */
        hinted = allocated(p, *(sqlite3_int64 *)argument);
        pthread_mutex_lock(&budgetLock);
        before = p->size;
        int fits = hinted <= p->size || charge(p, hinted - p->size, 0);
        if (fits && hinted > p->size) p->size = hinted;
        pthread_mutex_unlock(&budgetLock);
        if (!fits) return SQLITE_FULL;
    }
    int rc = p->real->pMethods->xFileControl(p->real, op, argument);
    if (op == SQLITE_FCNTL_CHUNK_SIZE && rc == SQLITE_OK && argument) p->chunk = *(int *)argument > 0 ? *(int *)argument : 0;
    /* The system may have grown the file past what was charged (a chunk size rounds up): the extra is taken. */
    if ((op == SQLITE_FCNTL_SIZE_HINT || op == SQLITE_FCNTL_CHUNK_SIZE) && p->group) {
        sqlite3_int64 actual = 0;
        if (p->real->pMethods->xFileSize(p->real, &actual) == SQLITE_OK) {
            pthread_mutex_lock(&budgetLock);
            sqlite3_int64 counted = p->size > before ? p->size : before;
            if (actual > counted) { chargeTaken(p, actual - counted); }
            if (actual > p->size) p->size = actual;
            pthread_mutex_unlock(&budgetLock);
        }
    }
    /* The VFS name SQLite reports includes this one. */
    if (op == SQLITE_FCNTL_VFSNAME && rc == SQLITE_OK) {
        char *inner = *(char **)argument;
        *(char **)argument = inner ? sqlite3_mprintf("%s/%z", NTP_BUDGET_VFS, inner) : sqlite3_mprintf("%s", NTP_BUDGET_VFS);
    }
    return rc;
}

static int budgetSectorSize(sqlite3_file *file) { return REAL(file)->pMethods->xSectorSize(REAL(file)); }
static int budgetDeviceCharacteristics(sqlite3_file *file) {
    return REAL(file)->pMethods->xDeviceCharacteristics(REAL(file));
}

static int budgetShmMap(sqlite3_file *file, int page, int size, int extend, void volatile **out) {
    return REAL(file)->pMethods->xShmMap(REAL(file), page, size, extend, out);
}
static int budgetShmLock(sqlite3_file *file, int offset, int n, int flags) {
    return REAL(file)->pMethods->xShmLock(REAL(file), offset, n, flags);
}
static void budgetShmBarrier(sqlite3_file *file) { REAL(file)->pMethods->xShmBarrier(REAL(file)); }
static int budgetShmUnmap(sqlite3_file *file, int deleteFlag) { return REAL(file)->pMethods->xShmUnmap(REAL(file), deleteFlag); }
static int budgetFetch(sqlite3_file *file, sqlite3_int64 offset, int amount, void **out) {
    return REAL(file)->pMethods->xFetch(REAL(file), offset, amount, out);
}
static int budgetUnfetch(sqlite3_file *file, sqlite3_int64 offset, void *pointer) {
    return REAL(file)->pMethods->xUnfetch(REAL(file), offset, pointer);
}

static const sqlite3_io_methods budgetIo1 = {
    1, budgetClose, budgetRead, budgetWrite, budgetTruncate, budgetSync, budgetFileSize, budgetLockFile, budgetUnlock,
    budgetCheckReserved, budgetFileControl, budgetSectorSize, budgetDeviceCharacteristics, 0, 0, 0, 0, 0, 0,
};
static const sqlite3_io_methods budgetIo2 = {
    2, budgetClose, budgetRead, budgetWrite, budgetTruncate, budgetSync, budgetFileSize, budgetLockFile, budgetUnlock,
    budgetCheckReserved, budgetFileControl, budgetSectorSize, budgetDeviceCharacteristics,
    budgetShmMap, budgetShmLock, budgetShmBarrier, budgetShmUnmap, 0, 0,
};
static const sqlite3_io_methods budgetIo3 = {
    3, budgetClose, budgetRead, budgetWrite, budgetTruncate, budgetSync, budgetFileSize, budgetLockFile, budgetUnlock,
    budgetCheckReserved, budgetFileControl, budgetSectorSize, budgetDeviceCharacteristics,
    budgetShmMap, budgetShmLock, budgetShmBarrier, budgetShmUnmap, budgetFetch, budgetUnfetch,
};

static int isBudgetFile(sqlite3_file *file) {
    return file && (file->pMethods == &budgetIo1 || file->pMethods == &budgetIo2 || file->pMethods == &budgetIo3);
}

/* MARK: - VFS methods */

static int budgetOpen(sqlite3_vfs *vfs, const char *name, sqlite3_file *file, int flags, int *outFlags) {
    (void)vfs;
    BudgetFile *p = (BudgetFile *)file;
    memset(p, 0, sizeof(BudgetFile));
    /* The inner file is sized for the file system it is opened on now. */
    sqlite3_vfs *inner = innerVfs();
    p->real = sqlite3_malloc(inner->szOsFile);
    if (!p->real) { p->base.pMethods = NULL; return SQLITE_NOMEM; }
    memset(p->real, 0, (size_t)inner->szOsFile);
    int rc = inner->xOpen(inner, name, p->real, flags, outFlags);
    if (rc != SQLITE_OK || !p->real->pMethods) {
        if (p->real->pMethods) p->real->pMethods->xClose(p->real);
        sqlite3_free(p->real);
        p->real = NULL;
        p->base.pMethods = NULL;
        return rc == SQLITE_OK ? SQLITE_CANTOPEN : rc;
    }
    switch (p->real->pMethods->iVersion) {
    case 1: p->base.pMethods = &budgetIo1; break;
    case 2: p->base.pMethods = &budgetIo2; break;
    default: p->base.pMethods = &budgetIo3; break;
    }
    const char *database = NULL;
    if (name && (flags & SQLITE_OPEN_MAIN_DB)) { p->kind = KindDatabase; database = name; }
    else if (name && (flags & SQLITE_OPEN_WAL)) { p->kind = KindWAL; database = sqlite3_filename_database(name); }
    else if (name && (flags & SQLITE_OPEN_MAIN_JOURNAL)) { p->kind = KindJournal; database = sqlite3_filename_database(name); }
    if (database) {
        sqlite3_int64 size = 0;
        if (p->real->pMethods->xFileSize(p->real, &size) != SQLITE_OK) size = 0;
        pthread_mutex_lock(&budgetLock);
        p->group = groupRetain(database);
        p->size = size;
        /* A WAL that survived the last process (killed before its frames were copied): its frames' checkpoint copies
           are still owed. Its size bounds them; the reservation is released once the WAL starts again. */
        if (p->group && p->kind == KindWAL && !p->group->walSeen) {
            p->group->walSeen = 1;
            if (size > p->group->reserved) p->group->reserved = size;
        }
        pthread_mutex_unlock(&budgetLock);
    }
    return SQLITE_OK;
}

static int budgetDelete(sqlite3_vfs *vfs, const char *name, int syncDirectory) {
    (void)vfs;
    return innerVfs()->xDelete(innerVfs(), name, syncDirectory);
}
static int budgetAccess(sqlite3_vfs *vfs, const char *name, int flags, int *out) {
    (void)vfs;
    return innerVfs()->xAccess(innerVfs(), name, flags, out);
}
static int budgetFullPathname(sqlite3_vfs *vfs, const char *name, int size, char *out) {
    (void)vfs;
    return innerVfs()->xFullPathname(innerVfs(), name, size, out);
}
static void *budgetDlOpen(sqlite3_vfs *vfs, const char *name) { (void)vfs; return innerVfs()->xDlOpen(innerVfs(), name); }
static void budgetDlError(sqlite3_vfs *vfs, int size, char *out) { (void)vfs; innerVfs()->xDlError(innerVfs(), size, out); }
static void (*budgetDlSym(sqlite3_vfs *vfs, void *handle, const char *symbol))(void) {
    (void)vfs;
    return innerVfs()->xDlSym(innerVfs(), handle, symbol);
}
static void budgetDlClose(sqlite3_vfs *vfs, void *handle) { (void)vfs; innerVfs()->xDlClose(innerVfs(), handle); }
static int budgetRandomness(sqlite3_vfs *vfs, int size, char *out) { (void)vfs; return innerVfs()->xRandomness(innerVfs(), size, out); }
static int budgetSleep(sqlite3_vfs *vfs, int microseconds) { (void)vfs; return innerVfs()->xSleep(innerVfs(), microseconds); }
static int budgetCurrentTime(sqlite3_vfs *vfs, double *out) { (void)vfs; return innerVfs()->xCurrentTime(innerVfs(), out); }
static int budgetGetLastError(sqlite3_vfs *vfs, int size, char *out) {
    (void)vfs;
    sqlite3_vfs *inner = innerVfs();
    return inner->xGetLastError ? inner->xGetLastError(inner, size, out) : 0;
}
static int budgetCurrentTimeInt64(sqlite3_vfs *vfs, sqlite3_int64 *out) {
    (void)vfs;
    return innerVfs()->xCurrentTimeInt64(innerVfs(), out);
}
static int budgetSetSystemCall(sqlite3_vfs *vfs, const char *name, sqlite3_syscall_ptr call) {
    (void)vfs;
    return innerVfs()->xSetSystemCall(innerVfs(), name, call);
}
static sqlite3_syscall_ptr budgetGetSystemCall(sqlite3_vfs *vfs, const char *name) {
    (void)vfs;
    return innerVfs()->xGetSystemCall(innerVfs(), name);
}
static const char *budgetNextSystemCall(sqlite3_vfs *vfs, const char *name) {
    (void)vfs;
    return innerVfs()->xNextSystemCall(innerVfs(), name);
}

int ntp_budget_register(void) {
    pthread_mutex_lock(&budgetLock);
    if (registered) { pthread_mutex_unlock(&budgetLock); return SQLITE_OK; }
    realVfs = sqlite3_vfs_find(NULL);
    if (!realVfs) { pthread_mutex_unlock(&budgetLock); return SQLITE_ERROR; }
    memset(&budgetVfs, 0, sizeof(budgetVfs));
    budgetVfs.iVersion = realVfs->iVersion < 3 ? realVfs->iVersion : 3;
    budgetVfs.szOsFile = (int)sizeof(BudgetFile);
    budgetVfs.mxPathname = realVfs->mxPathname;
    budgetVfs.zName = NTP_BUDGET_VFS;
    budgetVfs.xOpen = budgetOpen;
    budgetVfs.xDelete = budgetDelete;
    budgetVfs.xAccess = budgetAccess;
    budgetVfs.xFullPathname = budgetFullPathname;
    budgetVfs.xDlOpen = budgetDlOpen;
    budgetVfs.xDlError = budgetDlError;
    budgetVfs.xDlSym = budgetDlSym;
    budgetVfs.xDlClose = budgetDlClose;
    budgetVfs.xRandomness = budgetRandomness;
    budgetVfs.xSleep = budgetSleep;
    budgetVfs.xCurrentTime = budgetCurrentTime;
    budgetVfs.xGetLastError = budgetGetLastError;
    if (budgetVfs.iVersion >= 2) budgetVfs.xCurrentTimeInt64 = budgetCurrentTimeInt64;
    if (budgetVfs.iVersion >= 3) {
        budgetVfs.xSetSystemCall = budgetSetSystemCall;
        budgetVfs.xGetSystemCall = budgetGetSystemCall;
        budgetVfs.xNextSystemCall = budgetNextSystemCall;
    }
    int rc = sqlite3_vfs_register(&budgetVfs, 0);
    if (rc == SQLITE_OK) registered = 1;
    pthread_mutex_unlock(&budgetLock);
    return rc;
}

static BudgetGroup *groupOf(sqlite3 *db, const char *schema) {
    sqlite3_file *file = NULL;
    if (sqlite3_file_control(db, schema, SQLITE_FCNTL_FILE_POINTER, &file) != SQLITE_OK || !isBudgetFile(file)) return NULL;
    return ((BudgetFile *)file)->group;
}

int ntp_budget_arm(sqlite3 *db, const char *schema, sqlite3_int64 budget) {
    BudgetGroup *group = groupOf(db, schema);
    if (!group) return SQLITE_MISUSE;
    pthread_mutex_lock(&budgetLock);
    group->armed = 1;
    group->budget = budget;
    /* Checkpoint copies still owed from earlier arms are already spent. */
    group->charged = group->reserved;
    group->refused = 0;
    group->refusedCharge = 0;
    pthread_mutex_unlock(&budgetLock);
    return SQLITE_OK;
}

int ntp_budget_disarm(sqlite3 *db, const char *schema) {
    BudgetGroup *group = groupOf(db, schema);
    if (!group) return SQLITE_MISUSE;
    pthread_mutex_lock(&budgetLock);
    group->armed = 0;
    pthread_mutex_unlock(&budgetLock);
    return SQLITE_OK;
}

int ntp_budget_read(sqlite3 *db, const char *schema, ntp_budget_state *state) {
    BudgetGroup *group = groupOf(db, schema);
    if (!group || !state) return SQLITE_MISUSE;
    pthread_mutex_lock(&budgetLock);
    state->budget = group->budget;
    state->charged = group->charged;
    state->reserved = group->reserved;
    state->refused = group->refused;
    state->refused_charge = group->refusedCharge;
    state->armed = group->armed;
    pthread_mutex_unlock(&budgetLock);
    return SQLITE_OK;
}
