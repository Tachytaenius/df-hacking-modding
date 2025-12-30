// v47utils
// By Tachytaenius

// Used for summoning units in v0.47.05 in a way that is safe for use within event hooks etc, unlike modtools/create-unit (related to core (un)suspension)
// Also used to get cancel job code working in v0.47.05

#include <string>
#include <vector>

#include "Error.h"
#include "PluginManager.h"
#include "VersionInfo.h"
#include "MiscUtils.h"
#include "modules/Job.h"

#include "df/world.h"
#include "df/unit.h"
#include "df/interaction_effect_summon_unitst.h"
#include "df/job.h"
#include "df/job_handler.h"

using std::string;
using std::vector;

using namespace DFHack;

DFHACK_PLUGIN("v47utils");

static command_result do_command(color_ostream &out, vector<string> &parameters);

DFhackCExport command_result plugin_init(color_ostream &out, std::vector <PluginCommand> &commands) {
	commands.push_back(PluginCommand(
		plugin_name,
		"Utilities for hacking/modding in v47",
		do_command));

	return CR_OK;
}

static intptr_t getRebaseDelta() {
	return Core::getInstance().vinfo->getRebaseDelta();
}

static command_result do_summon_command(color_ostream &out, vector<string> &parameters);
static command_result do_remove_job_command(color_ostream &out, vector<string> &parameters);

static command_result do_command(color_ostream &out, vector<string> &parameters) {
	string cmd;
	if (!parameters.empty()) {
		cmd = parameters[0];
	}

	if (cmd == "summon") {
		return do_summon_command(out, parameters);
	} else if (cmd == "remove-job") {
		return do_remove_job_command(out, parameters);
	} else {
		if (!parameters.empty() && cmd != "?") {
			out.printerr("Invalid command: %s\n", cmd.c_str());
		}
		return CR_WRONG_USAGE;
	}
}

static command_result do_summon_command(color_ostream &out, vector<string> &parameters) {
	// TODO: Actual argument parameter checking etc so's not to crash
	if (parameters.size() != 5+1) {
		out.printerr("Usage: v47utils summon raceId casteId x y z\n");
		return CR_WRONG_USAGE;
	}

	int32_t raceId = std::stoi(parameters[1]);
	int16_t casteId = std::stoi(parameters[2]);
	int16_t x = std::stoi(parameters[3]);
	int16_t y = std::stoi(parameters[4]);
	int16_t z = std::stoi(parameters[5]);

	CoreSuspender suspend;

	auto interactionEffect = df::allocate<df::interaction_effect_summon_unitst>();
	interactionEffect->unk_1.push_back(raceId);
	interactionEffect->unk_2.push_back(casteId);

	// Credit to Quietust for finding the addresses!
	// TODO: Test all.
	#if defined(_WIN32)
		#ifdef DFHACK64
			size_t address = 0x1402066f0;
		#else
			size_t address = 0x005b8840;
		#endif
	#elif defined(_DARWIN)
		#ifdef DFHACK64
			size_t address = 0x10025b750;
		#else
			size_t address = 0x002a12d0;
		#endif
	#elif defined(_LINUX)
		#ifdef DFHACK64
			size_t address = 0x004f5b10;
		#else
			size_t address = 0x08161d60;
		#endif
	#else
		#error Unknown OS
	#endif

	typedef void (THISCALL *summonUnitFunc)(
		df::world *,
		df::unit *,
		df::interaction_effect_summon_unitst *,
		short,
		short,
		short
	);
	summonUnitFunc summonUnit = (summonUnitFunc)(address + getRebaseDelta());
	summonUnit(df::global::world, nullptr, interactionEffect, x, y, z);

	delete interactionEffect;

	return CR_OK;
}

bool fixedRemoveJob(df::job* job) {
	// Based on DFHack::Job::removeJob
	// Has the code from DFHack PR 3713 backported

	using df::global::world;
	CHECK_NULL_POINTER(job);

	// cancel_job below does not clean up all refs, so we have to do some work

	// manually handle DESTROY_BUILDING jobs (cancel_job doesn't handle them)
	if (job->job_type == df::job_type::DestroyBuilding) {
		for (auto &genRef : job->general_refs) {
			DFHack::Job::disconnectJobGeneralRef(job, genRef);
			if (genRef) delete genRef;
		}
		job->general_refs.resize(0);

		// remove the job from the world
		job->list_link->prev->next = job->list_link->next;
		delete job->list_link;
		delete job;
		return true;
	}

	// clean up item refs and delete them
	for (auto &item_ref : job->items) {
		DFHack::Job::disconnectJobItem(job, item_ref);
		if (item_ref) delete item_ref;
	}
	job->items.resize(0);

	// call the job cancel vmethod graciously provided by The Toady One.
	// job_handler::cancel_job calls job::~job, and then deletes job (this has
	// been confirmed by disassembly).

	// From DFHack PR 3713 (i.e. not my code):
	// HACK: GCC (starting around GCC 10 targeting C++20 as of v50.09) optimizes
	// out the vmethod call here regardless of optimization level, so we need to
	// invoke the vmethod manually through a pointer, as the Lua wrapper does.
	// `volatile` does not seem to be necessary but is included for good
	// measure.
	volatile auto cancel_job_method = &df::job_handler::cancel_job;
	(world->jobs.*cancel_job_method)(job);

	return true;
}

static command_result do_remove_job_command(color_ostream &out, vector<string> &parameters) {
	if (parameters.size() != 1+1) {
		out.printerr("Usage: v47utils remove-job jobId\n");
		return CR_WRONG_USAGE;
	}

	// TODO: Actual argument parameter checking etc so's not to crash
	int32_t jobId = std::stoi(parameters[1]);

	using df::global::world;
	df::job_list_link *link = world->jobs.list.next;
	for (; link; link = link->next) {
		int listId = link->item->id;
		if (listId == jobId) {
			fixedRemoveJob(link->item);
			break;
		}
	}

	return CR_OK;
}
