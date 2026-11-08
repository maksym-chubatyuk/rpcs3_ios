// iOS frontend glue: emulator callbacks, the render surface, firmware installation and boot control.
// Plays the part of rpcs3qt/main_application + gui_application on desktop.

#include "stdafx.h"
#include "rpcs3_ios.h"

#include "ios/jit_pool.hpp"
#include "ios/userdata.hpp"
#include "util/sysinfo.hpp"
#include "Utilities/JIT.h"
#include "Utilities/File.h"
#include "Utilities/Thread.h"
#include "Crypto/unself.h"
#include "Crypto/key_vault.h"
#include "Loader/PUP.h"
#include "Loader/TAR.h"
#include "Emu/System.h"
#include "Emu/system_config.h"
#include "Emu/system_utils.hpp"
#include "Emu/emu_callbacks.h"
#include "Emu/VFS.h"
#include "Emu/vfs_config.h"
#include "Emu/IdManager.h"
#include "Emu/RSX/GSFrameBase.h"
#include "Emu/RSX/RSXThread.h"
#include "Emu/RSX/Core/RSXRendererFactory.h"
#include "Emu/RSX/Overlays/overlay_utils.h"
#include "Emu/localized_string_id.h"
#include "Emu/Audio/AudioBackend.h"
#include "Emu/Audio/Null/NullAudioBackend.h"
#include "Emu/Audio/Null/null_enumerator.h"
#include "Emu/Audio/Cubeb/CubebBackend.h"
#include "Emu/Audio/Cubeb/cubeb_enumerator.h"
#ifdef HAVE_FAUDIO
#include "Emu/Audio/FAudio/FAudioBackend.h"
#include "Emu/Audio/FAudio/faudio_enumerator.h"
#endif
#include "Emu/Io/Null/NullKeyboardHandler.h"
#include "Emu/Io/Null/NullMouseHandler.h"
#include "Emu/Io/Null/null_camera_handler.h"
#include "Emu/Io/Null/null_music_handler.h"
#include "Emu/Cell/Modules/cellMsgDialog.h"
#include "Emu/Cell/Modules/cellOskDialog.h"
#include "Emu/Cell/Modules/cellSaveData.h"
#include "Emu/Cell/Modules/sceNpTrophy.h"
#include "Emu/RSX/Overlays/overlay_manager.h"
#include "Emu/RSX/Overlays/overlay_trophy_notification.h"
#include "util/video_source.h"
#include "Input/pad_thread.h"
#include "Emu/Cell/PPUThread.h"
#include "Emu/Cell/SPUThread.h"
#include "Emu/Io/pad_config.h"
#include "util/video_source.h"

#ifdef HAVE_SDL3
#include "Input/sdl_instance.h"
#define SDL_MAIN_HANDLED
#include <SDL3/SDL.h>
#include <SDL3/SDL_main.h>
#endif

#define STB_IMAGE_WRITE_IMPLEMENTATION
#define STBI_WRITE_NO_STDIO_HACKS
#include <stb_image_write.h>

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#include <mach/mach.h>
#include <unistd.h>
#include <os/proc.h>
#include <vulkan/vulkan.h>

#include <clocale>
#include <cstdio>

LOG_CHANNEL(ios_log, "iOS");

// The Vulkan device the app renders with (defined below, after the bridge's helpers)
std::string ios_vulkan_adapter();

namespace
{
	rpcs3_ios_event_fn g_events = nullptr;

	// Render surface (set by the app)
	atomic_t<void*> g_view{nullptr};
	atomic_t<s32> g_view_width{1280};
	atomic_t<s32> g_view_height{720};
	atomic_t<u64> g_view_refresh_bits{std::bit_cast<u64>(60.0)};

	void notify(rpcs3_ios_event e)
	{
		if (auto fn = g_events)
		{
			fn(e);
		}
	}

	// The game window: a UIView backed by a CAMetalLayer. MoltenVK presents into the layer.
	// RPCS3 plays animated save icons (ICON1.PAM) and a game's boot music through a video source,
	// Qt Multimedia on desktop. None exists here yet: this one never has a frame, so the save
	// dialog shows the still icon and boot music stays silent (RPCS3 requires a source to exist).
	class ios_video_source final : public video_source
	{
	public:
		void set_iso_path(const std::string&) override {}
		void set_video_path(const std::string&, bool) override {}
		void set_audio_path(const std::string&, bool) override {}
		void set_active(bool active) override { m_active = active; }
		bool get_active() const override { return m_active; }
		bool has_new() const override { return false; }
		void get_image(std::vector<u8>&, int& w, int& h, int& ch, int& bpp) override { w = h = ch = bpp = 0; }

	private:
		bool m_active = false;
	};

	// Trophy popups in the game's picture, through RPCS3's own overlay (as its desktop frontend
	// does whenever the overlays are running, which they always are here)
	class ios_trophy_notification final : public TrophyNotificationBase
	{
	public:
		s32 ShowTrophyNotification(const SceNpTrophyDetails& trophy, const std::vector<uchar>& icon) override
		{
			if (auto manager = g_fxo->try_get<rsx::overlays::display_manager>())
			{
				auto popup = std::make_shared<rsx::overlays::trophy_notification>();
				return manager->add(popup, false)->show(trophy, icon);
			}

			return 0;
		}
	};

	// Overlay sounds (RPCS3 looks for them in its config folder's sounds/; there are none by default)
	void play_sound(const std::string& path, std::optional<f32> volume)
	{
		NSURL* url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path.c_str()]];

		if (![NSFileManager.defaultManager fileExistsAtPath:url.path])
		{
			return;
		}

		dispatch_async(dispatch_get_main_queue(), ^{
			static NSMutableSet<AVAudioPlayer*>* s_playing = [NSMutableSet set];
			AVAudioPlayer* player = [[AVAudioPlayer alloc] initWithContentsOfURL:url error:nil];

			if (!player)
			{
				return;
			}

			player.volume = volume ? *volume : 1.0f;
			[s_playing addObject:player];
			[player play];

			// Kept until it has finished
			dispatch_after(dispatch_time(DISPATCH_TIME_NOW, static_cast<int64_t>((player.duration + 1) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
				[s_playing removeObject:player];
			});
		});
	}

	class ios_gs_frame final : public GSFrameBase
	{
	public:
		void close() override {}
		void reset() override {}
		video_renderer renderer() const override { return video_renderer::vulkan; }
		bool shown() override { return true; }
		void hide() override {}
		void show() override {}
		void toggle_fullscreen() override {}
		void delete_context(draw_context_t) override {}
		draw_context_t make_context() override { return nullptr; }
		void set_current(draw_context_t) override {}
		void flip(draw_context_t, bool) override {}
		int client_width() override { return g_view_width; }
		int client_height() override { return g_view_height; }
		f64 client_display_rate() override { return std::bit_cast<f64>(g_view_refresh_bits.load()); }
		bool has_alpha() override { return false; }
		display_handle_t handle() const override { return g_view.load(); }
		bool can_consume_frame() const override { return false; }
		void present_frame(std::vector<u8>&&, u32, u32, u32, bool) const override {}
		// Screenshots go to Documents/screens/ as PNG (also used by the test hook, RPCS3_SCREENSHOT_EVERY)
		void take_screenshot(std::vector<u8>&& data, u32 width, u32 height, bool is_bgra) override
		{
			if (data.size() < usz{width} * height * 4)
			{
				return;
			}

			if (is_bgra)
			{
				for (usz i = 0; i + 3 < data.size(); i += 4)
				{
					std::swap(data[i], data[i + 2]);
				}
			}

			for (usz i = 3; i < data.size(); i += 4)
			{
				data[i] = 0xff;
			}

			static atomic_t<u32> s_index = 0;
			const std::string dir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject UTF8String] + std::string("/screens/");
			fs::create_path(dir);
			const std::string path = fmt::format("%sshot-%03u.png", dir, s_index++);
			stbi_write_png(path.c_str(), static_cast<int>(width), static_cast<int>(height), 4, data.data(), static_cast<int>(width * 4));
			ios_log.notice("Screenshot saved: %s (%ux%u)", path, width, height);
		}
		void update_title(double) override {}
	};

	void run_on_main_thread(std::function<void()> func, atomic_t<u32>* wake_up)
	{
		auto done = [wake_up]()
		{
			if (wake_up)
			{
				*wake_up = true;
				wake_up->notify_one();
			}
		};

		if ([NSThread isMainThread])
		{
			func();
			done();
			return;
		}

		auto* task = new std::function<void()>([func = std::move(func), done]() { func(); done(); });

		dispatch_async(dispatch_get_main_queue(), ^{
			(*task)();
			delete task;
		});
	}

	std::string localized_string(localized_string_id id, const char* arg)
	{
		std::string text;

		switch (id)
		{
#define X(name, value) case localized_string_id::name: text = value; break;
#include "localized_strings.inc"
#undef X
		default: text = "Unknown"; break;
		}

		// As QString::arg: every %0 takes the argument
		for (usz pos = text.find("%0"); pos != umax; pos = text.find("%0", pos))
		{
			const std::string_view value = arg ? arg : "";
			text.replace(pos, 2, value);
			pos += value.size();
		}

		return text;
	}

	// RPCS3 looks for its overlay images (home menu, trophies) in the emulator folder before its
	// macOS resources folder; the app bundles them (rpcs3.app/Icons), so link them there. The bundle
	// moves with every install, so the link is made again at each launch.
	void use_bundled_icons()
	{
		const std::string bundled = std::string([[NSBundle mainBundle].bundlePath UTF8String]) + "/Icons";
		const std::string link = fs::get_config_dir() + "Icons";

		if (!fs::is_dir(bundled))
		{
			return;
		}

		::unlink(link.c_str());

		if (::symlink(bundled.c_str(), link.c_str()) != 0)
		{
			ios_log.error("Could not link the bundled icons to %s (errno %d)", link, errno);
		}
	}

	// RPCS3's default controls are the keyboard. On iOS player 1 is the app's controller (touch
	// controls merged with any physical controller), which the core exposes as an SDL virtual gamepad.
	void add_default_input_config()
	{
		constexpr std::string_view virtual_pad = "RPCS3 Virtual Pad 1";
		const std::string& profile = g_cfg_input_configs.default_config;
		const std::string path = rpcs3::utils::get_input_config_dir() + profile + ".yml";
		// Written once (v2: an earlier build saved the virtual pad with the keyboard's button names)
		const std::string marker = fs::get_config_dir() + "default_input_v2";

		if (fs::is_file(marker) && fs::is_file(path))
		{
			return;
		}

		cfg_input config;

		if (fs::is_file(path) && config.load("", profile, true) &&
			!(config.player[0]->handler == pad_handler::sdl && config.player[0]->device.to_string() == virtual_pad))
		{
			// Someone's own configuration: keep it
			fs::write_file(marker, fs::rewrite, std::string("1"));
			return;
		}

		config.from_default();
		config.player[0]->handler.set(pad_handler::sdl);
		std::shared_ptr<PadHandlerBase> handler;
		pad_thread::InitPadConfig(config.player[0]->config, pad_handler::sdl, handler);
		config.player[0]->device.from_string(virtual_pad);
		config.save("", profile);
		fs::write_file(marker, fs::rewrite, std::string("1"));
		ios_log.notice("Wrote the default input configuration (player 1: the app's controller)");
	}

	// What a configuration needs to work on iOS (see app/rpcs3/Settings/SettingsPolicy.swift for the
	// settings the app does not offer). True if something changed.
	bool apply_ios_requirements(cfg_root& cfg)
	{
		bool changed = false;
		const auto require = [&](auto& setting, auto value)
		{
			if (setting.get() != value)
			{
				setting.set(value);
				changed = true;
			}
		};

		// Vulkan through MoltenVK is the only renderer
		require(cfg.video.renderer, video_renderer::vulkan);
#ifdef HAVE_FAUDIO
		// cubeb has no iOS backend in RPCS3; FAudio plays through SDL3 (Core Audio)
		if (cfg.audio.renderer.get() == audio_renderer::cubeb)
			require(cfg.audio.renderer, audio_renderer::faudio);
#endif
		// RPCS3's own dialogs (save data, messages, on-screen keyboard) are the only ones: its Qt
		// fallbacks do not exist on iOS
		require(cfg.misc.use_native_interface, true);
		// Metal compiles the shader interpreter's pipelines for minutes before a game starts
		if (cfg.video.shadermode.get() == shader_mode::async_with_interpreter || cfg.video.shadermode.get() == shader_mode::interpreter_only)
			require(cfg.video.shadermode, shader_mode::async_recompiler);
		// Both make RPCS3 import guest memory into Vulkan buffers (passthrough DMA), which MoltenVK
		// cannot do: vkCreateBuffer fails for host allocations and the renderer stops
		require(cfg.video.vk.asynchronous_texture_streaming, false);
		require(cfg.video.host_label_synchronization, false);
		// No microphone access (the app has no microphone permission; iOS would end it on first use)
		require(cfg.audio.microphone_type, microphone_handler::null);
		// Qt's and SDL's cameras are not available; the fake camera is
		if (cfg.io.camera.get() == camera_handler::qt || cfg.io.camera.get() == camera_handler::sdl)
			require(cfg.io.camera, camera_handler::null);
		// The ASMJIT SPU recompiler exists only for x86
		if (cfg.core.spu_decoder.get() == spu_decoder_type::asmjit)
			require(cfg.core.spu_decoder, spu_decoder_type::llvm);
		// The one GPU (a config from another device names its own)
		if (const std::string adapter = ios_vulkan_adapter(); !adapter.empty() && cfg.video.vk.adapter.to_string() != adapter)
		{
			cfg.video.vk.adapter.from_string(adapter);
			changed = true;
		}

		return changed;
	}

	void create_callbacks()
	{
		auto& cb = g_emu_callbacks;

		cb.call_from_main_thread = run_on_main_thread;

		cb.on_run = [](bool) { notify(RPCS3_IOS_EVENT_RUN); };
		cb.on_pause = []() { notify(RPCS3_IOS_EVENT_PAUSE); };
		cb.on_resume = []() { notify(RPCS3_IOS_EVENT_RESUME); };
		cb.on_stop = []() { notify(RPCS3_IOS_EVENT_STOP); };
		cb.on_ready = []() { notify(RPCS3_IOS_EVENT_READY); };
		cb.on_missing_fw = []() { notify(RPCS3_IOS_EVENT_MISSING_FIRMWARE); };

		cb.on_emulation_stop_no_response = [](std::shared_ptr<atomic_t<bool>> closed_successfully, int seconds)
		{
			if (!closed_successfully || !*closed_successfully)
			{
				ios_log.error("Stopping the emulator has taken %d seconds; some thread is probably stuck.", seconds);
			}
		};

		cb.on_save_state_progress = [](std::shared_ptr<atomic_t<bool>>, stx::shared_ptr<utils::serial>, stx::atomic_ptr<std::string>*, std::shared_ptr<void>) {};
		cb.enable_disc_eject = [](bool) {};
		cb.enable_disc_insert = [](bool) {};
		cb.try_to_quit = [](bool force_quit, std::function<void()> on_exit) -> bool
		{
			// An iOS app does not quit itself; stopping emulation is all that is asked for here.
			if (on_exit)
			{
				on_exit();
			}

			return force_quit;
		};
		cb.handle_taskbar_progress = [](s32, s32) {};

		cb.init_kb_handler = []()
		{
			ensure(g_fxo->init<KeyboardHandlerBase, NullKeyboardHandler>(Emu.DeserialManager()));
		};

		cb.init_mouse_handler = []()
		{
			ensure(g_fxo->init<MouseHandlerBase, NullMouseHandler>(Emu.DeserialManager()));
		};

		cb.init_pad_handler = [](std::string_view title_id)
		{
			ensure(g_fxo->init<named_thread<pad_thread>>(nullptr, nullptr, title_id));

			// Wait until the pad thread is up, as the desktop frontend does
			while (!pad::g_started && !Emu.IsStopped())
			{
				std::this_thread::sleep_for(1ms);
			}
		};

		cb.update_emu_settings = []()
		{
			Emu.CallFromMainThread([]()
			{
				rpcs3::utils::configure_logs(Emu.IsStopped());
			});
		};

		cb.save_emu_settings = []()
		{
			Emulator::SaveSettings(g_cfg.to_string(), Emu.GetTitleID());
		};

		cb.close_gs_frame = []() {};
		cb.get_gs_frame = []() -> std::unique_ptr<GSFrameBase> { return std::make_unique<ios_gs_frame>(); };
		cb.replace_gs_frame = []() -> std::unique_ptr<GSFrameBase> { return std::make_unique<ios_gs_frame>(); };
		cb.init_gs_render = [](utils::serial* ar)
		{
			// The config a game boots with may come from anywhere (RPCS3's defaults, a game's own
			// settings, a file from desktop): what iOS needs applies before the renderer starts
			if (apply_ios_requirements(g_cfg))
			{
				ios_log.warning("Adjusted this boot's configuration for iOS");
			}

			rsx::create_render_thread(ar);
		};

		cb.get_camera_handler = []() -> std::shared_ptr<camera_handler_base> { return std::make_shared<null_camera_handler>(); };
		cb.get_music_handler = []() -> std::shared_ptr<music_handler_base> { return std::make_shared<null_music_handler>(); };

		cb.get_audio = []() -> std::shared_ptr<AudioBackend>
		{
			std::shared_ptr<AudioBackend> result;

			switch (g_cfg.audio.renderer.get())
			{
			case audio_renderer::null: result = std::make_shared<NullAudioBackend>(); break;
#ifdef HAVE_FAUDIO
			// cubeb has no iOS backend in RPCS3: a config asking for it gets FAudio
			case audio_renderer::cubeb:
			case audio_renderer::faudio: result = std::make_shared<FAudioBackend>(); break;
#else
			case audio_renderer::cubeb: result = std::make_shared<CubebBackend>(); break;
#endif
			default: result = std::make_shared<NullAudioBackend>(); break;
			}

			if (!result->Initialized())
			{
				ios_log.error("Audio renderer %s could not be initialized, using the Null renderer.", result->GetName());
				result = std::make_shared<NullAudioBackend>();
			}

			return result;
		};

		cb.get_audio_enumerator = [](u64 renderer) -> std::shared_ptr<audio_device_enumerator>
		{
			switch (static_cast<audio_renderer>(renderer))
			{
#ifdef HAVE_FAUDIO
			case audio_renderer::cubeb:
			case audio_renderer::faudio: return std::make_shared<faudio_enumerator>();
#else
			case audio_renderer::cubeb: return std::make_shared<cubeb_enumerator>();
#endif
			default: return std::make_shared<null_enumerator>();
			}
		};

		// Dialogs: none yet (games see the "no dialog" path, as in headless mode)
		cb.get_msg_dialog = []() -> std::shared_ptr<MsgDialogBase> { return nullptr; };
		cb.get_osk_dialog = []() -> std::shared_ptr<OskDialogBase> { return nullptr; };
		cb.get_save_dialog = []() -> std::unique_ptr<SaveDialogBase> { return nullptr; };
		cb.get_sendmessage_dialog = []() -> std::shared_ptr<SendMessageDialogBase> { return nullptr; };
		cb.get_recvmessage_dialog = []() -> std::shared_ptr<RecvMessageDialogBase> { return nullptr; };
		cb.get_trophy_notification_dialog = []() -> std::unique_ptr<TrophyNotificationBase> { return std::make_unique<ios_trophy_notification>(); };

		// The overlays' texts (home menu, dialogs...), in English; the Qt frontend's table, generated
		cb.get_localized_string = [](localized_string_id id, const char* arg) { return localized_string(id, arg); };
		cb.get_localized_u32string = [](localized_string_id id, const char* arg) { return utf8_to_u32string(localized_string(id, arg)); };
		// Home menu dropdowns: the setting's own value names, as the config file has them
		cb.get_localized_setting = [](const cfg::_base* node, u32 index) -> std::string
		{
			if (!node)
				return {};
			const auto names = node->to_list();
			return index < names.size() ? names[index] : std::string{};
		};

		cb.get_photo_path = [](std::string_view title)
		{
			return vfs::get(fmt::format("/dev_hdd0/photo/%s", vfs::escape(title, true)));
		};

		cb.play_sound = [](const std::string& path, std::optional<f32> volume) { play_sound(path, volume); };
		cb.get_image_info = [](const std::string&, std::string&, s32&, s32&, s32&) { return false; };
		cb.get_scaled_image = [](const std::string&, s32, s32, s32&, s32&, u8*, bool) { return false; };

		cb.resolve_path = [](std::string_view sv) -> std::string
		{
			char buf[PATH_MAX];
			const std::string path(sv);
			return ::realpath(path.c_str(), buf) ? std::string(buf) : std::string();
		};

		cb.resolve_path_may_not_exist = [](std::string_view sv) -> std::string { return std::string(sv); };

		cb.get_font_dirs = []() { return std::vector<std::string>{}; };

		cb.on_install_pkgs = [](const std::vector<std::string>& pkgs, bool from_optical_drive)
		{
			for (const std::string& pkg : pkgs)
			{
				if (!rpcs3::utils::install_pkg(pkg, from_optical_drive))
				{
					ios_log.error("Failed to install %s", pkg);
					return false;
				}
			}

			return true;
		};

		cb.add_breakpoint = [](u32) {};
		// "Prevent display sleep while running games": the screen stays on while a game runs
		cb.display_sleep_control_supported = []() { return true; };
		cb.enable_display_sleep = [](bool enabled)
		{
			dispatch_async(dispatch_get_main_queue(), ^{ UIApplication.sharedApplication.idleTimerDisabled = !enabled; });
		};
		cb.check_microphone_permissions = []() {};
		cb.make_video_source = []() -> std::unique_ptr<video_source> { return std::make_unique<ios_video_source>(); };
		cb.enable_gamemode = [](bool) {};
		cb.get_database_config = [](const std::string&) { return std::string(); };
	}

	std::string g_fw_version;

	// The task's address map and the free space in it, for the log: VA is the scarce resource on iOS.
	void log_address_space(const char* when)
	{
		task_vm_info_data_t vmi{};
		mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
		task_info(mach_task_self(), TASK_VM_INFO, reinterpret_cast<task_info_t>(&vmi), &count);

		u64 free_total = 0, free_largest = 0;
		vm_address_t at = static_cast<vm_address_t>(vmi.min_address);

		while (at < vmi.max_address)
		{
			vm_address_t region = at;
			vm_size_t size = 0;
			vm_region_basic_info_data_64_t info;
			mach_msg_type_number_t n = VM_REGION_BASIC_INFO_COUNT_64;
			mach_port_t object = MACH_PORT_NULL;
			const bool found = vm_region_64(mach_task_self(), &region, &size, VM_REGION_BASIC_INFO_64, reinterpret_cast<vm_region_info_t>(&info), &n, &object) == KERN_SUCCESS;
			const u64 hole_end = found ? std::min<u64>(region, vmi.max_address) : vmi.max_address;

			if (hole_end > at)
			{
				free_total += hole_end - at;
				free_largest = std::max<u64>(free_largest, hole_end - at);
			}

			if (!found)
			{
				break;
			}

			at = region + size;
		}

		ios_log.notice("Address space (%s): map 0x%llx-0x%llx, free %llu MiB (largest hole %llu MiB); footprint %llu MiB, available memory %llu MiB",
			when, vmi.min_address, vmi.max_address, free_total >> 20, free_largest >> 20, vmi.phys_footprint >> 20, static_cast<u64>(os_proc_available_memory()) >> 20);
	}

	// The GPU's name as MoltenVK reports it: RPCS3 needs a default adapter for Vulkan
	// (the desktop frontend gets it the same way, through its render_creator).
	std::string vulkan_adapter_name()
	{
		VkApplicationInfo app{VK_STRUCTURE_TYPE_APPLICATION_INFO};
		app.pApplicationName = "RPCS3";
		app.apiVersion = VK_API_VERSION_1_2;

		VkInstanceCreateInfo info{VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO};
		info.pApplicationInfo = &app;

		VkInstance instance = VK_NULL_HANDLE;

		if (vkCreateInstance(&info, nullptr, &instance) != VK_SUCCESS)
		{
			return {};
		}

		u32 count = 0;
		vkEnumeratePhysicalDevices(instance, &count, nullptr);
		std::vector<VkPhysicalDevice> devices(count);
		vkEnumeratePhysicalDevices(instance, &count, devices.data());

		std::string name;

		if (count)
		{
			VkPhysicalDeviceProperties props{};
			vkGetPhysicalDeviceProperties(devices[0], &props);
			// The name RPCS3 gives this adapter (vk::physical_device::get_name): MoltenVK's device
			// name does not mention the driver, so RPCS3 appends it. A different name here makes
			// RPCS3 think the GPU changed and replace the renderer mid-boot.
			name = std::string(props.deviceName) + " (MoltenVK)";
		}

		vkDestroyInstance(instance, nullptr);
		return name;
	}

#ifdef HAVE_SDL3
	// The app's controller, as an SDL virtual gamepad that RPCS3's SDL pad handler binds to
	// player 1 like any physical one (see the iOS default in Emu/Io/pad_config.cpp).
	std::mutex g_pad_mutex;
	SDL_Joystick* g_pad = nullptr;

	void create_virtual_pad()
	{
		std::lock_guard lock(g_pad_mutex);

		if (g_pad || !sdl_instance::get_instance().initialize())
		{
			return;
		}

		SDL_VirtualJoystickDesc desc;
		SDL_INIT_INTERFACE(&desc);
		desc.type = SDL_JOYSTICK_TYPE_GAMEPAD;
		desc.naxes = SDL_GAMEPAD_AXIS_COUNT;
		desc.nbuttons = SDL_GAMEPAD_BUTTON_COUNT;
		desc.button_mask = (1u << SDL_GAMEPAD_BUTTON_COUNT) - 1;
		desc.axis_mask = (1u << SDL_GAMEPAD_AXIS_COUNT) - 1;
		desc.name = "RPCS3 Virtual Pad";

		const SDL_JoystickID id = SDL_AttachVirtualJoystick(&desc);

		if (!id || !(g_pad = SDL_OpenJoystick(id)))
		{
			ios_log.error("Could not create the virtual gamepad: %s", SDL_GetError());
			return;
		}

		ios_log.notice("Virtual gamepad ready (SDL joystick %u)", id);
	}
#endif
}

// The Vulkan device the app renders with, for settings.cpp (its default for Video/Vulkan/Adapter)
std::string ios_vulkan_adapter()
{
	static const std::string name = vulkan_adapter_name();
	return name;
}

// Frontend globals the core and the input code refer to (rpcs3.cpp, rpcs3qt on desktop)
std::string g_input_config_override;
cfg_input_configurations g_cfg_input_configs;

void qt_events_aware_op(int repeat_duration_ms, std::function<bool()> wrapped_op)
{
	// No Qt event loop to keep alive: just poll
	while (!wrapped_op())
	{
		std::this_thread::sleep_for(std::chrono::milliseconds(std::max(repeat_duration_ms, 1)));
	}
}

// Frontend hook the core calls on unrecoverable errors (rpcs3.cpp on desktop).
[[noreturn]] void report_fatal_error(std::string_view text, bool /*is_html*/, bool /*include_help_text*/)
{
	std::fprintf(stderr, "RPCS3: fatal error:\n%.*s\n", static_cast<int>(text.size()), text.data());

	// Keep the message for the app to show on its next launch
	if (fs::file f{fs::get_config_dir() + "fatal_error.txt", fs::rewrite})
	{
		f.write(text.data(), text.size());
	}

	logs::listener::sync_all();
	std::abort();
}

extern "C" int rpcs3_ios_jit_available(void)
{
	return utils::jit_pool::available() ? 1 : 0;
}

extern "C" int rpcs3_ios_initialize(rpcs3_ios_event_fn events)
{
	g_events = events;

	std::setlocale(LC_NUMERIC, "C");

	if (!utils::jit_pool::available())
	{
		std::fprintf(stderr, "RPCS3: no JIT pool, the emulator cannot start\n");
		return -1;
	}

	// As rpcs3.cpp does on desktop: the thread pool finalizer first, then the log file
	static_cast<void>(named_thread("", [](int) {}));
	static std::unique_ptr<logs::listener> s_log_file = logs::make_file_listener(fs::get_log_dir() + "RPCS3.log", 256ull << 20);
	fs::remove_file(fs::get_config_dir() + "fatal_error.txt");
	ios_log.always()("RPCS3 for iOS; JIT pool ready");
	ios_log.always()("CPU features: sha3=%d sha512=%d dotprod=%d i8mm=%d sve=%d sve2=%d; LLVM CPU '%s'",
		utils::has_sha3(), utils::has_sha512(), utils::has_dotprod(), utils::has_i8mm(), utils::has_sve(), utils::has_sve2(),
		jit_compiler::cpu(g_cfg.core.llvm_cpu.to_string()));
	log_address_space("startup");

	// Shader caches written before the exact D24 depth upload (ShuffleBytes.glsl) can hold fragment
	// programs corrupted by the depth round trip; drop them once so they are rebuilt from the real ucode.
	if (const std::string marker = fs::get_cache_dir() + "shader_cache_d24_fix"; !fs::is_file(marker))
	{
		const std::string root = fs::get_cache_dir() + "cache/";

		for (const auto& title : fs::dir(root))
		{
			if (!title.is_directory || title.name == "." || title.name == "..")
				continue;

			for (const auto& build : fs::dir(root + title.name))
			{
				if (build.is_directory && build.name != "." && build.name != ".." && fs::is_dir(root + title.name + "/" + build.name + "/shaders_cache"))
				{
					fs::remove_all(root + title.name + "/" + build.name + "/shaders_cache");
					ios_log.notice("Removed shader cache of %s/%s (written before the D24 fix)", title.name, build.name);
				}
			}
		}

		fs::write_file(marker, fs::rewrite, std::string("1"));
	}

	create_callbacks();

#ifdef HAVE_SDL3
	// SDL is used as a library here; there is no SDL_main
	SDL_SetMainReady();
#endif

	// Vulkan through MoltenVK is the only renderer on iOS
	const std::string adapter = vulkan_adapter_name();

	if (!adapter.empty())
	{
		std::fprintf(stderr, "RPCS3: Vulkan adapter '%s'\n", adapter.c_str());
		Emu.SetSupportedRenderers({video_renderer::null, video_renderer::vulkan});
		Emu.SetDefaultRenderer(video_renderer::vulkan);
		Emu.SetDefaultGraphicsAdapter(adapter);
	}
	else
	{
		std::fprintf(stderr, "RPCS3: no Vulkan device (MoltenVK); only the null renderer is available\n");
		Emu.SetSupportedRenderers({video_renderer::null});
		Emu.SetDefaultRenderer(video_renderer::null);
	}

	Emu.SetHasGui(true);
	Emu.SetHeadless(false);
	Emu.SetUsr(ios_userdata::saved_user());
	Emu.Init();

	use_bundled_icons();
	add_default_input_config();

	// The global config: what iOS needs, saved, as booting a game reloads it from disk
	bool fixed = apply_ios_requirements(g_cfg);

	// Test hook (scripts/run.sh PERF_OVERLAY=1): RPCS3's performance overlay, saved in the config
	if (const char* overlay = std::getenv("RPCS3_PERF_OVERLAY"); overlay && g_cfg.video.perf_overlay.enabled.get() != (overlay[0] == '1'))
	{
		g_cfg.video.perf_overlay.enabled.set(overlay[0] == '1');
		fixed = true;
	}

	if (fixed)
	{
		Emulator::SaveSettings(g_cfg.to_string(), "");
	}

#ifdef HAVE_SDL3
	create_virtual_pad();
#endif

	const std::string fw = utils::get_firmware_version();
	ios_log.always()("Firmware version: %s", fw.empty() ? "missing" : fw);
	rpcs3::utils::configure_logs(true);
	return 0;
}

extern "C" const char* rpcs3_ios_emulator_dir(void)
{
	static const std::string dir = rpcs3::utils::get_emu_dir();
	return dir.c_str();
}

extern "C" const char* rpcs3_ios_log_dir(void)
{
	return fs::get_log_dir().c_str();
}

extern "C" const char* rpcs3_ios_firmware_version(void)
{
	g_fw_version = utils::get_firmware_version();
	return g_fw_version.c_str();
}

extern "C" int rpcs3_ios_install_firmware(const char* pup_path, rpcs3_ios_progress_fn progress, void* ctx, char* error, uint32_t error_size)
{
	const auto fail = [&](int code, std::string_view msg)
	{
		ios_log.error("Firmware installation failed: %s", msg);

		if (error && error_size)
		{
			std::snprintf(error, error_size, "%.*s", static_cast<int>(msg.size()), msg.data());
		}

		return code;
	};

	fs::file pup_f(pup_path ? pup_path : "");

	if (!pup_f)
	{
		return fail(-1, "The file could not be opened.");
	}

	pup_object pup(std::move(pup_f));

	if (pup.operator pup_error() != pup_error::ok)
	{
		return fail(-2, "This is not a valid PS3 firmware file (PS3UPDAT.PUP).");
	}

	fs::file update_files_f = pup.get_file(0x300);

	if (!update_files_f || !update_files_f.size())
	{
		return fail(-3, "The firmware file is damaged (no package database).");
	}

	tar_object update_files(update_files_f);

	auto filenames = update_files.get_filenames();
	std::erase_if(filenames, [](const std::string& s) { return s.find("dev_flash_") == umax; });

	if (filenames.empty())
	{
		return fail(-4, "The firmware file is damaged (no dev_flash packages).");
	}

	vfs::mount("/dev_flash", g_cfg_vfs.get_dev_flash());

	u32 done = 0;
	const u32 total = ::size32(filenames);

	for (const auto& name : filenames)
	{
		auto stream = update_files.get_file(name);

		if (stream->m_file_handler)
		{
			// Forcefully read all the data
			stream->m_file_handler->handle_file_op(*stream, 0, stream->get_size(umax), nullptr);
		}

		fs::file update_file = fs::make_stream(std::move(stream->data));

		SCEDecrypter self_dec(update_file);
		self_dec.LoadHeaders();
		self_dec.LoadMetadata(SCEPKG_ERK, SCEPKG_RIV);
		self_dec.DecryptData();

		auto dev_flash_tar_f = self_dec.MakeFile();

		if (dev_flash_tar_f.size() < 3)
		{
			return fail(-5, "The firmware could not be decompressed.");
		}

		tar_object dev_flash_tar(dev_flash_tar_f[2]);

		if (!dev_flash_tar.extract())
		{
			return fail(-6, fmt::format("The firmware contents could not be extracted (%s).", name));
		}

		if (progress)
		{
			progress(ctx, ++done, total);
		}
	}

	ios_log.success("Installed firmware %s", utils::get_firmware_version());
	return 0;
}

extern "C" int rpcs3_ios_install_pkg(const char* pkg_path)
{
	return rpcs3::utils::install_pkg(pkg_path ? pkg_path : "", false) ? 0 : -1;
}

extern "C" void rpcs3_ios_set_pad(const rpcs3_ios_pad* pad)
{
#ifdef HAVE_SDL3
	std::lock_guard lock(g_pad_mutex);

	if (!g_pad)
	{
		return;
	}

	static const rpcs3_ios_pad s_rest{};
	const rpcs3_ios_pad& p = pad ? *pad : s_rest;

	static constexpr std::pair<u32, SDL_GamepadButton> s_buttons[] =
	{
		{RPCS3_IOS_PAD_CROSS, SDL_GAMEPAD_BUTTON_SOUTH},
		{RPCS3_IOS_PAD_CIRCLE, SDL_GAMEPAD_BUTTON_EAST},
		{RPCS3_IOS_PAD_SQUARE, SDL_GAMEPAD_BUTTON_WEST},
		{RPCS3_IOS_PAD_TRIANGLE, SDL_GAMEPAD_BUTTON_NORTH},
		{RPCS3_IOS_PAD_L1, SDL_GAMEPAD_BUTTON_LEFT_SHOULDER},
		{RPCS3_IOS_PAD_R1, SDL_GAMEPAD_BUTTON_RIGHT_SHOULDER},
		{RPCS3_IOS_PAD_L3, SDL_GAMEPAD_BUTTON_LEFT_STICK},
		{RPCS3_IOS_PAD_R3, SDL_GAMEPAD_BUTTON_RIGHT_STICK},
		{RPCS3_IOS_PAD_SELECT, SDL_GAMEPAD_BUTTON_BACK},
		{RPCS3_IOS_PAD_START, SDL_GAMEPAD_BUTTON_START},
		{RPCS3_IOS_PAD_PS, SDL_GAMEPAD_BUTTON_GUIDE},
		{RPCS3_IOS_PAD_UP, SDL_GAMEPAD_BUTTON_DPAD_UP},
		{RPCS3_IOS_PAD_DOWN, SDL_GAMEPAD_BUTTON_DPAD_DOWN},
		{RPCS3_IOS_PAD_LEFT, SDL_GAMEPAD_BUTTON_DPAD_LEFT},
		{RPCS3_IOS_PAD_RIGHT, SDL_GAMEPAD_BUTTON_DPAD_RIGHT},
	};

	for (const auto& [bit, button] : s_buttons)
	{
		SDL_SetJoystickVirtualButton(g_pad, button, (p.buttons & bit) != 0);
	}

	const auto stick = [](float v) { return static_cast<Sint16>(std::clamp(v, -1.0f, 1.0f) * (v < 0 ? 32768.0f : 32767.0f)); };
	// A virtual gamepad's triggers rest at SDL_JOYSTICK_AXIS_MIN and are fully pressed at the maximum;
	// 0 would read as half pressed (games then see L2/R2 held, and some menus ignore the D-pad)
	const auto trigger = [](float v) { return static_cast<Sint16>(std::lround(std::clamp(v, 0.0f, 1.0f) * 65535.0f) - 32768); };

	// SDL's Y axes point down
	SDL_SetJoystickVirtualAxis(g_pad, SDL_GAMEPAD_AXIS_LEFTX, stick(p.lx));
	SDL_SetJoystickVirtualAxis(g_pad, SDL_GAMEPAD_AXIS_LEFTY, stick(-p.ly));
	SDL_SetJoystickVirtualAxis(g_pad, SDL_GAMEPAD_AXIS_RIGHTX, stick(p.rx));
	SDL_SetJoystickVirtualAxis(g_pad, SDL_GAMEPAD_AXIS_RIGHTY, stick(-p.ry));
	SDL_SetJoystickVirtualAxis(g_pad, SDL_GAMEPAD_AXIS_LEFT_TRIGGER, trigger(p.l2));
	SDL_SetJoystickVirtualAxis(g_pad, SDL_GAMEPAD_AXIS_RIGHT_TRIGGER, trigger(p.r2));
#else
	(void)pad;
#endif
}

extern "C" void rpcs3_ios_set_render_view(void* uiview, int32_t width, int32_t height, double refresh_rate)
{
	g_view = uiview;
	g_view_width = std::max<s32>(width, 1);
	g_view_height = std::max<s32>(height, 1);
	g_view_refresh_bits = std::bit_cast<u64>(refresh_rate > 0 ? refresh_rate : 60.0);
}

int ios_boot_game(const std::string& path, const std::string& title_id, cfg_mode mode, const std::string& config_path);

extern "C" int rpcs3_ios_boot(const char* path)
{
	return ios_boot_game(path ? path : "", "", cfg_mode::custom, "");
}

int ios_boot_game(const std::string& path, const std::string& title_id, cfg_mode mode, const std::string& config_path)
{
	if (!g_view)
	{
		ios_log.error("Boot requested without a render view");
		return -1;
	}

	log_address_space("before boot");
	const game_boot_result result = Emu.BootGame(path, title_id, false, mode, config_path);
	log_address_space("after boot");

	// Test hook (scripts/run.sh PS_AFTER=<seconds>): presses the PS button once, as the touch controller does
	if (const char* after = std::getenv("RPCS3_PS_AFTER"); after && result == game_boot_result::no_errors)
	{
		std::thread([seconds = std::max(1, std::atoi(after))]()
		{
			std::this_thread::sleep_for(std::chrono::seconds(seconds));
			rpcs3_ios_pad pad{};
			pad.buttons = RPCS3_IOS_PAD_PS;
			rpcs3_ios_set_pad(&pad);
			std::this_thread::sleep_for(std::chrono::milliseconds(300));
			rpcs3_ios_set_pad(nullptr);
		}).detach();
	}

	// Test hook (scripts/run.sh SCREENSHOT_EVERY=<seconds>): periodic screenshots into Documents/screens
	if (const char* every = std::getenv("RPCS3_SCREENSHOT_EVERY"); every && result == game_boot_result::no_errors)
	{
		const int seconds = std::max(1, std::atoi(every));

		std::thread([seconds]()
		{
			extern atomic_t<bool> g_user_asked_for_screenshot;

			for (int i = 0; i < 40 && !Emu.IsStopped(); i++)
			{
				std::this_thread::sleep_for(std::chrono::seconds(seconds));
				g_user_asked_for_screenshot = true;
			}
		}).detach();
	}

	// Test hook (scripts/run.sh DUMP_AFTER=<seconds>): write every PPU and SPU thread's guest state
	// (registers, call stack) into the log, to see what a game waits on
	if (const char* after = std::getenv("RPCS3_DUMP_AFTER"); after && result == game_boot_result::no_errors)
	{
		const int seconds = std::atoi(after);

		std::thread([seconds]()
		{
			std::this_thread::sleep_for(std::chrono::seconds(seconds));

			idm::select<named_thread<ppu_thread>>([](u32, named_thread<ppu_thread>& cpu)
			{
				std::string dump;
				cpu.dump_all(dump);
				ios_log.notice("Thread dump (PPU):\n%s", dump);
			});

			idm::select<named_thread<spu_thread>>([](u32, named_thread<spu_thread>& cpu)
			{
				std::string dump;
				cpu.dump_all(dump);
				ios_log.notice("Thread dump (SPU):\n%s", dump);
			});

			logs::listener::sync_all();
		}).detach();
	}

	if (result != game_boot_result::no_errors)
	{
		ios_log.error("Boot failed: %s", result);
	}

	return static_cast<int>(result);
}

extern "C" void rpcs3_ios_pause(void)
{
	Emu.Pause();
}

extern "C" void rpcs3_ios_resume(void)
{
	Emu.Resume();
}

extern "C" void rpcs3_ios_stop(void)
{
	Emu.GracefulShutdown(false, true);
}

extern "C" int rpcs3_ios_state(void)
{
	return static_cast<int>(Emu.GetStatus(false));
}
