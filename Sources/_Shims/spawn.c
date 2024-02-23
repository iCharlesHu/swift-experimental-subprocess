//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
//
//===----------------------------------------------------------------------===//

#include <unistd.h>
#include "include/conditionals.h"

#if TARGET_OS_MAC
#include "include/shims.h"
#include <sys/wait.h>
#include <errno.h>

int _subprocess_spawn(
    pid_t  * _Nonnull  pid,
    const char  * _Nonnull  exec_path,
    const posix_spawn_file_actions_t _Nullable * _Nonnull file_actions,
    const posix_spawnattr_t _Nullable * _Nonnull spawn_attrs,
    char * _Nullable const args[_Nonnull],
    char * _Nullable const env[_Nullable],
    uid_t * _Nullable uid,
    gid_t * _Nullable gid,
    int number_of_sgroups, const gid_t * _Nullable sgroups,
    int create_session
) {
    int require_pre_fork = uid != NULL ||
        gid != NULL ||
        number_of_sgroups > 0 ||
    create_session > 0;

    if (require_pre_fork != 0) {
        pid_t childPid = fork();
        if (childPid != 0) {
            *pid = childPid;
            return childPid < 0 ? errno : 0;
        }

        if (uid != NULL) {
            if (setuid(*uid) != 0) {
                return errno;
            }
        }

        if (gid != NULL) {
            if (setgid(*gid) != 0) {
                return errno;
            }
        }

        if (number_of_sgroups > 0 && sgroups != NULL) {
            if (setgroups(number_of_sgroups, sgroups) != 0) {
                return errno;
            }
        }

        if (create_session != 0) {
            (void)setsid();
        }
    }

    // Set POSIX_SPAWN_SETEXEC if we already forked
    if (require_pre_fork) {
        short flags = 0;
        int rc = posix_spawnattr_getflags(spawn_attrs, &flags);
        if (rc != 0) {
            return rc;
        }

        rc = posix_spawnattr_setflags(
            (posix_spawnattr_t *)spawn_attrs, flags | POSIX_SPAWN_SETEXEC);
        if (rc != 0) {
            return rc;
        }
    }

    // Spawn
    return posix_spawn(pid, exec_path, file_actions, spawn_attrs, args, env);
}

#endif // TARGET_OS_MAC
