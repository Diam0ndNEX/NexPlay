// NexPlay-Bridging-Header.h
//
// libarchive ships with iOS (linked with -larchive, see project.yml), but the iOS SDK has no headers for it.
// The few functions ArchiveExtractor.swift uses are declared here with the signatures of libarchive 3.x
// (archive.h / archive_entry.h, BSD-2-Clause). Linking the system libarchive this way is how Empo reads 7z and RAR
// (Empo, Copyright (C) 2026 Mateo M., https://github.com/mateo-m/empo-app, GPL-3.0-only with additional terms).

#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

struct archive;
struct archive_entry;

struct archive *archive_read_new(void);
int archive_read_support_filter_all(struct archive *);
int archive_read_support_format_all(struct archive *);
int archive_read_open_filename(struct archive *, const char *_filename, size_t _block_size);
int archive_read_next_header(struct archive *, struct archive_entry **);
int archive_read_data_block(struct archive *a, const void **buff, size_t *size, int64_t *offset);
int archive_read_data_skip(struct archive *);
int archive_read_free(struct archive *);
const char *archive_error_string(struct archive *);
int64_t archive_filter_bytes(struct archive *, int);

const char *archive_entry_pathname(struct archive_entry *);
const char *archive_entry_pathname_utf8(struct archive_entry *);
mode_t archive_entry_filetype(struct archive_entry *);
