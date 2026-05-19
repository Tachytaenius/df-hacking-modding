// rubblecompute
// By Tachytaenius

// Speeding up the computations for my rubble mod

#include <string>
#include <vector>

#include "Error.h"
#include "PluginManager.h"
#include "VersionInfo.h"
#include "modules/Units.h"
#include "modules/Maps.h"

#include "df/world.h"
#include "df/unit.h"
#include "df/unit_action_type.h"
#include "df/map_block.h"

using std::string;
using std::vector;

using namespace DFHack;

DFHACK_PLUGIN("rubblecompute");

static command_result do_command(color_ostream &out, vector<string> &parameters);

DFhackCExport command_result plugin_init(color_ostream &out, std::vector <PluginCommand> &commands) {
	commands.push_back(PluginCommand(
		plugin_name,
		"Code to speed up the computations for my rubble mod",
		do_command));

	return CR_OK;
}

static command_result do_slowdown_command(color_ostream &out, vector<string> &parameters);

static command_result do_command(color_ostream &out, vector<string> &parameters) {
	string cmd;
	if (!parameters.empty()) {
		cmd = parameters[0];
	}

	if (cmd == "slowdown") {
		return do_slowdown_command(out, parameters);
	} else {
		if (!parameters.empty() && cmd != "?") {
			out.printerr("Invalid command: %s\n", cmd.c_str());
		}
		return CR_WRONG_USAGE;
	}
}

static command_result do_slowdown_command(color_ostream &out, vector<string> &parameters) {
	// TODO: Actual argument parameter checking etc so's not to crash
	if (parameters.size() != 1+1) {
		out.printerr("Usage: rubblecompute slowdown <multiplier>\n");
		return CR_WRONG_USAGE;
	}
	float multiplier = std::stof(parameters[1]);
	const int32_t handledMoveActionFlagMask = 1 << 31; // Bit 31, like in the Lua version

	CoreSuspender suspend;

	for (auto unit : df::global::world->units.active) {
		// TODO: Test invalid positions and blocks etc
		bool boulderPresent = false;
		auto pos = Units::getPosition(unit);
		if (!pos.isValid()) {
			continue;
		}
		auto block = Maps::getTileBlock(pos);
		if (!block) {
			continue;
		}
		auto lx = pos.x % 16;
		auto ly = pos.y % 16;
		if (!block->occupancy[lx][ly].bits.item) {
			boulderPresent = false;
		} else {
			for (size_t i = 0; i < block->items.size(); i++) {
				auto item = df::item::find(block->items[i]);
				if (!item) {
					continue;
				}
				if (item->getType() != df::item_type::BOULDER) {
					continue;
				}
				if (item->pos != pos) {
					continue;
				} 
				boulderPresent = true;
				break;
			}
		}

		if (boulderPresent) {
			for (auto action : unit->actions) {
				switch (action->type) {
				case df::unit_action_type::Move:
					// TODO: Skip if flying
					if (!(action->data.move.flags.whole & handledMoveActionFlagMask)) {
						action->data.move.flags.whole |= handledMoveActionFlagMask;

						int32_t timeUsed = action->data.move.timer_init - action->data.move.timer;
						int32_t newTimerInit = max(1, (int)(action->data.move.timer_init * multiplier));
						int32_t newTimer = max(1, newTimerInit - timeUsed);
						action->data.move.timer_init = newTimerInit;
						action->data.move.timer = newTimer;
					}
					break;
				case df::unit_action_type::Job:
					if (!(action->data.move.flags.whole & handledMoveActionFlagMask)) {
						action->data.move.flags.whole |= handledMoveActionFlagMask;
						action->data.job.timer = max(1, (int)(action->data.job.timer * multiplier));
					}
					break;
				default:
					break;
				}
			}
		}
	}

	return CR_OK;
}
