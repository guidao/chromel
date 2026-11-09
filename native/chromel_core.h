// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <string>

namespace chromel {
void initialize(const std::string& bundle, const std::string& profile, int debuggingPort = 0);
long bind_window(const std::string& title);
int create(long window, const std::string& url);
void layout(int id, long window, double x, double y, double width, double height);
void hide(int id);
void command(int id, const std::string& action, const std::string& argument);
void pump();
std::string events();
std::string info();
std::string inspect(int id);
void shutdown();
}
