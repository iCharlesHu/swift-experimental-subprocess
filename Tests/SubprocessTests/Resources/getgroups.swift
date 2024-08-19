import Darwin

let ngroups = getgroups(0, nil)
guard ngroups >= 0 else {
    perror("ngroups should be > 0")
    exit(1)
}
var groups = [gid_t](repeating: 0, count: Int(ngroups))
guard getgroups(ngroups, &groups) >= 0 else {
    perror("getgroups failed")
    exit(errno)
}
let result = groups.map{ String($0) }.joined(separator: ",")
print(result)
