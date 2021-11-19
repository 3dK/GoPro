Sync, join and convert from GoPro device when plugged in USB

Description

	1 - When GoPro is plugged in USB port, UDEV will start a SYSTEMD service (gopro.tcl auto move)
	2 - Videos will be moved to local storage (UNPROCESSED_VIDEOS). Message is sent when finished
	3 - Videos are joined (JOINED_VIDEOS) on daily timeframe (06:00:00 - 05:59:59 (of next day)) in sequential order
	4 - Daily videos (YYYYMMDD.mp4) are transcoded using x264/x265 (CONVERTED_VIDEOS)

Usage

Automatic
	
	Next step is called after previous is finished (auto move -> auto join -> auto convert):
	- Transfer all images and videos from GoPro, join and covert videos: "gopro.tcl auto move" -> auto join -> auto convert
	- Join all videos and convert: "gopro.tcl auto join" -> auto convert
	- Convert all videos: "gopro.tcl auto convert"
	All files within default directories will be processed: move (UNPROCESSED_VIDEOS), join (JOINED_VIDEOS) and convert (CONVERTED_VIDEOS)
Manual

	Only invoked step is performed on all or specified files:
	- Transfer all images and videos from GOPRO_MNT to UNPROCESSED_VIDEOS: "gopro.tcl manual move"
	- Join videos to JOINED_VIDEOS: "gopro.tcl manual join [*]"
	- Convert videos to CONVERTED_VIDEOS: "gopro.tcl manual convert [*]"
	[*] If no files are specified, default path is used for input/output and all files are processed
	[*] If filenames are specified, only these files from default input path will be processed
	[*] If logical/physical path to files is provided, resulting output will be stored in default path

Instalation

	Enable UDEV rule (99-gopro.rules)
	Enable SYSTEMD service (gopro@service)
	Create mounting directory for GPHOTOFS

Requirements

	GPhotoFS
	FFMpeg
	Tcl 8.6

To-do

	Parallel service execution not working. While "auto move" service is running, other "auto move" will be ignored
	Move converted videos to backup storage with proper ownership/permissions for cloud usage
