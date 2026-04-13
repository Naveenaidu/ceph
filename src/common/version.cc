// -*- mode:C++; tab-width:8; c-basic-offset:2; indent-tabs-mode:nil -*-
// vim: ts=8 sw=2 sts=2 expandtab

/*
 * Ceph - scalable distributed file system
 *
 * Copyright (C) 2011 New Dream Network
 *
 * This is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License version 2.1, as published by the Free Software
 * Foundation.  See file COPYING.
 *
 */

#include "common/version.h"

#include <stdlib.h>
#include <sstream>
#include <fstream>
#include <string>
#include <iterator>


#include "ceph_ver.h"
#include "common/ceph_strings.h"

#define _STR(x) #x
#define STRINGIFY(x) _STR(x)

static std::string g_vendor_version;
static constexpr size_t MAX_VENDOR_VERSION_SIZE = 256;

const char *ceph_version_to_str()
{
  char* debug_version_for_testing = getenv("ceph_debug_version_for_testing");
  if (debug_version_for_testing) {
    return debug_version_for_testing;
  } else {
    return CEPH_GIT_NICE_VER;
  }
}

const char *ceph_release_to_str(void)
{
  return ceph_release_name(CEPH_RELEASE);
}

const char *git_version_to_str(void)
{
  return STRINGIFY(CEPH_GIT_VER);
}

void ceph_set_vendor_version_file(const std::string& path)
{
  std::ifstream file(path);
  if (!file.is_open()) {
    g_vendor_version.clear();
    return;
  }

  std::string content;
  try {
    content.reserve(MAX_VENDOR_VERSION_SIZE);
    for (std::istreambuf_iterator<char> it(file), end; it != end; ++it) {
      if (content.size() == MAX_VENDOR_VERSION_SIZE) {
        g_vendor_version.clear();
        return;
      }
      content.push_back(*it);
    }
  } catch (const std::exception &e) {
    g_vendor_version.clear();
    return;
  }

  while (!content.empty() &&
         (content.back() == '\n' || content.back() == '\r')) {
    content.pop_back();
  }

  if (!content.empty()) {
    g_vendor_version = " release " + content;
  } else {
    g_vendor_version.clear();
  }
}

std::string const pretty_version_to_str(void)
{
  std::ostringstream oss;
  oss << "ceph version " << CEPH_GIT_NICE_VER
      << " (" << STRINGIFY(CEPH_GIT_VER) << ") "
      << ceph_release_name(CEPH_RELEASE)
      << " (" << CEPH_RELEASE_TYPE << " - "
      << CEPH_BUILD_TYPE << ")"
#ifdef WITH_CRIMSON
      << " (crimson)"
#endif
      << g_vendor_version
      ;
  return oss.str();
}

const char *ceph_release_type(void)
{
  return CEPH_RELEASE_TYPE;
}
