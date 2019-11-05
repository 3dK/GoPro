#!/usr/bin/tclsh8.6
#
# Author:		Eduard Kulchinsky 
#
# Title:		Sync, join and convert from GoPro device when plugged in USB
#
# Description:	1 - When GoPro is plugged in USB port, UDEV will start a SYSTEMD service (gopro.tcl auto move)
#				2 - Videos will be moved to local storage (UNPROCESSED_VIDEOS). Message is sent when finished
#				3 - Videos are joined (JOINED_VIDEOS) on daily timeframe (06:00:00 - 05:59:59 (of next day)) in sequential order
#				4 - Daily videos (YYYYMMDD.mp4) are transcoded using x264/x265 (CONVERTED_VIDEOS)
#
# Usage:		Automatic
#					Next step is called after previous is finished (auto move -> auto join -> auto convert):
#						Transfer all images and videos from GoPro, join and covert videos: "gopro.tcl auto move" -> auto join -> auto convert
#						Join all videos and convert: "gopro.tcl auto join" -> auto convert
#						Convert all videos: "gopro.tcl auto convert"
#					All files within default directories will be processed: move (UNPROCESSED_VIDEOS), join (JOINED_VIDEOS) and convert (CONVERTED_VIDEOS)
#				Manual
#					Only invoked step is performed on all or specified files:
#						Transfer all images and videos from GOPRO_MNT to UNPROCESSED_VIDEOS: "gopro.tcl manual move"
#						Join videos to JOINED_VIDEOS: "gopro.tcl manual join [*]"
#						Convert videos to CONVERTED_VIDEOS: "gopro.tcl manual convert [*]"
#					[*] If no files are specified, default path is used for input/output and all files are processed
#					[*] If filenames are specified, only these files from default input path will be processed
#					[*] If logical/physical path to files is provided, resulting output will be stored in default path
#
# Instalation:	Enable UDEV rule (99-gopro.rules)
#				Enable SYSTEMD service (gopro@service)
#				Create mounting directory for GPHOTOFS
#
# Requirements:	GPhotoFS
#				FFMpeg
#
# To-do:		Parallel service execution not working. While "auto move" service is running, other "auto move" will be ignored
#				Move converted videos to backup storage with proper ownership/permissions for cloud usage
#


# Paths for video processing
set GOPRO_MNT "/mnt/gopro"
set GOPRO_HOME "/home/3dk/gopro"
set UNPROCESSED_VIDEOS "videos/unprocessed"
set JOINED_VIDEOS "videos/joined"
set CONVERTED_VIDEOS "videos/converted"

# Required Linux software
set DF [exec which df]
set PS [exec which ps]
set CURL [exec which curl]
set NICE "[exec which nice] -n10"
set RSYNC [exec which rsync]
set IONICE "[exec which ionice] -c3"
set FFMPEG [exec which ffmpeg]
set FFPROBE [exec which ffprobe]
set GPHOTOFS [exec which gphotofs]
set FUSERMOUNT [exec which fusermount]

# Push notification settings
# Get from https://llamalab.com/automate/cloud/
set PUSH_SECRET {}
set PUSH_ACCOUNT {}
set PUSH_DEVICE {}
set PUSH_ADDRESS {https://llamalab.com/automate/cloud/message}

# Control settins
set DAY_RESET 06; # 6AM
set SCAN_WAIT [expr 1000 * 60]; # 1min


# Procedure to send push notification
proc pushNotification { device message } {
	if { [catch { exec $::CURL  -f -s \
		--data "secret=$::PUSH_SECRET" --data-urlencode "to=$::PUSH_ACCOUNT" \
		--data-urlencode "device=${device}" --data-urlencode "payload=${message}" \
		$::PUSH_ADDRESS } msg] } {
        puts "Failed to send push notification: $msg"
	} else {
		puts "Push notification sent successfully to device \"$device\": $message"
	}
}

# Procedure to find "folderName" recursively
proc findFolder { path folderName } {
	puts -nonewline "."
	flush stdout
	
	foreach result [glob -nocomplain -dir $path -types d -- *]  {
		if { [file tail $result] == $folderName } {
			return $result
		} else {
			set result [findFolder $result $folderName]
			if { [file tail $result] == $folderName } {
				return $result
			}
		}
	}
}

# Procedure to move files to destination with RSYNC
proc moveFiles { files destination } {
	foreach moveFile $files {
		set time [clock seconds]
		set returnCode 1
		
		puts -nonewline "[file tail $moveFile] "
		
		while { $returnCode } {
			if { [catch { eval exec $::NICE $::IONICE $::RSYNC -aq --remove-source-files $moveFile [file normalize $destination] } msg] } {
				# Failed: 1
				set returnCode 1
			} else {
				# Success: 0
				set returnCode 0
			}
		}
		
		puts "\[elapsed [formatTimeInterval [expr [clock seconds] - $time]]\]"
	}
	
	return $returnCode
}

# Convert [clock seconds] interval to days, hours, minutes and seconds
proc formatTimeInterval {intervalSeconds} {
    set s [expr {$intervalSeconds % 60}]
    set i [expr {$intervalSeconds / 60}]
    set m [expr {$i % 60}]
    set i [expr {$i / 60}]
    set h [expr {$i % 24}]
    set d [expr {$i / 24}]
    
	return [format "%02d days %02d hours %02d minutes %02d seconds" $d $h $m $s]
}

if { [lsearch -nocase -exact [list "auto" "manual"] [lindex $argv 0]] < 0 } {
	puts "Unkown option: \"[lindex $argv 0]\". Valid options are: \"auto\" or \"manual move|join|convert\". Exiting"
	exit
}

set scriptTime [clock seconds]
puts "Script \"[file tail [info script]] [lindex $argv 0] [lindex $argv 1]\" started on: [clock format $scriptTime -format "%Y-%m-%d %T"]"
for {set idx 0} {$idx < [llength $argv]} {incr idx} {
	puts "\t${idx}: [lindex $argv $idx]"
}
puts ""

switch -nocase -- [lindex $argv 1] {
	"move" {
		# Script to move video/image files from GoPro to destination for further processing
		if {[expr int([lindex [exec df $GOPRO_HOME] 10]/(32*1024*1024)) < 1]} {
			puts "Not enough space; at least 32GB are required. Exiting"
			exit
		}
		
		# Mount GoPro
		puts "Mounting GoPro disk on: $GOPRO_MNT"
		if { [catch { eval exec $GPHOTOFS $GOPRO_MNT } msg] } {
			puts "Problem mounting GoPro disk or it is mounted already"
		} else {
			puts "Successfully mounted"
		}

		puts -nonewline "Scanning GoPro for DCIM folder "
		
		set searchTime [clock seconds]
		set dcim_folder [findFolder $GOPRO_MNT "DCIM"]
		puts " \[[lrange [formatTimeInterval [expr [clock seconds] - $searchTime]] end-1 end]\]"
		
		if { $dcim_folder != "" } {
			puts "Folder DCIM found under: $dcim_folder"
		}

		# Process every folder inside DCIM for video/image files
		foreach folder [glob -nocomplain -dir $dcim_folder -types d -- "*GOPRO"] {
			# Process only if video/image files exist
			if { [llength [glob -nocomplain -dir $folder -- "*.MP4"]] || [llength [glob -nocomplain -dir $folder -- "*.JPG"]] } {
				puts "\nFound video/image files under: [file tail $folder]"
				
				set videoFiles [glob -nocomplain -dir $folder -- "*.MP4"]
				set imageFiles [glob -nocomplain -dir $folder -- "*.JPG"]
				set thumbFiles [glob -nocomplain -dir $folder -- "*.THM"]
				
				puts -nonewline "Videos: [llength $videoFiles] \[ "
				foreach videoFile $videoFiles {
					puts -nonewline "[file tail $videoFile] "
				}
				puts "\]"
				
				puts -nonewline "Images: [llength $imageFiles] \[ "
				foreach imageFile $imageFiles {
					puts -nonewline "[file tail $imageFile] "
				}
				puts "\]"
				
				puts "Thumbnails: [llength $thumbFiles]"
				
				# Move video files one by one
				if { [llength $videoFiles] } {
					puts "\nMoving video files from [file tail $folder] to [file join $GOPRO_HOME $UNPROCESSED_VIDEOS]:"
					
					if { [moveFiles $videoFiles [file join $GOPRO_HOME $UNPROCESSED_VIDEOS]] } {
						set failedToMove 1
						puts "Failed to move all video files from GoPro"
					} else {
						foreach videoFile $videoFiles {
							lappend movedVideos [file normalize [file join $GOPRO_HOME $UNPROCESSED_VIDEOS [file tail $videoFile]]]
						}
					}
				}
				
				# Move all image files
				if { [llength $imageFiles] } {
					puts "\nMoving image files from [file tail $folder] to [file join $GOPRO_HOME "images"]:"
					if { [moveFiles $imageFiles [file join $GOPRO_HOME "images"]] } {
						puts "Failed to move image files: $imageFiles"
					}
				}
				
				# Delete all thumbnail files
				if { [llength $thumbFiles] } {
					puts "\nDeleting thumbnail files from [file tail $folder]"
					file delete $thumbFiles
				}
			} else {
				puts "No files found under: [file tail $folder]"
				continue
			}
			
			puts "Finished processing folder [file tail $folder]"
		}

		# Unmount GoPro disk
		puts "Unmounting GoPro disk: $GOPRO_MNT"
		
		if { [catch { eval exec $FUSERMOUNT -u $GOPRO_MNT } msg] } {
			puts "Disk must be unmounted manually with command: $FUSERMOUNT -u $GOPRO_MNT"
		} else {
			puts "Disk successfully unmounted"
		}
		
		# Send push notification to PUSH_DEVICE
		pushNotification $PUSH_DEVICE "GoPro can now be disconnected"
		
		# When finished, call join script if in auto mode
		switch -nocase -- [lindex $argv 0] {
			"auto" {
				if { [info exists failedToMove] } {
					if { $failedToMove } {
						puts "Not all videos were moved: \"[file tail [info script]] auto join\" won't be executed."
						pushNotification $PUSH_DEVICE "GoPro Not all videos were moved"
					}
				} else {				
					if { [info exists movedVideos] } {
						if { [llength $movedVideos] } {
							puts "Calling [file tail [info script]] auto join $movedVideos"
							catch { eval exec [file normalize [info script]] "auto" "join" {*}$movedVideos 2>@ stderr >@ stdout }
						}
					} else {
						puts "No videos were moved"
					}
				}
			}
			
			default {
				puts "Run \"[file tail [info script]] manual join\" to join moved videos"
			}
		}
	}
	
	"join" {
		# Script to join video files based on automatically splitted files, grouped by day
		set videoFiles [list]
		array set dailyVideos [list]
		
		if { $argc > 2 } {
			puts -nonewline "Parse user/system specified files: "
			
			foreach videoFile [lrange $argv 2 end] {
				if { [file exists $videoFile] } {
					# Full path
					lappend videoFiles [file normalize $videoFile]
				} else {
					# Filename only
					lappend videoFiles [file normalize [glob -nocomplain -dir [file join $GOPRO_HOME $UNPROCESSED_VIDEOS] -types f -- [file tail $videoFile]]]
				}
				
				# If added file doesn't exist, remove from list
				if { ![file exists [lindex $videoFiles end]] } {
					set videoFiles [lrange $videoFiles 0 end-1]
				}
			}
		} else {
			puts -nonewline "Parse all video files under [file join $GOPRO_HOME $UNPROCESSED_VIDEOS]: "
			
			foreach videoFile [lsort -nocase [glob -nocomplain -dir [file join $GOPRO_HOME $UNPROCESSED_VIDEOS] -types f -- "*.MP4"]] {
				lappend videoFiles [file normalize $videoFile]
			}
		}
		
		puts -nonewline "[llength $videoFiles] \["
		flush stdout
		
		# Extract timestamp from every file
		foreach videoFile $videoFiles {
			if { [catch { eval exec $NICE $FFPROBE $videoFile } ffprobe] } {
				regexp {creation_time\s+:\s+(\d\d\d\d-\d\d-\d\dT\d\d:\d\d:\d\d)} $ffprobe -> videoDate
				set videoDate [clock scan $videoDate -format "%Y-%m-%dT%T"]
				
				regexp {Duration:\s+(\d+):(\d+):(\d+)} $ffprobe -> hours minutes seconds
				set videoDuration [clock scan "$hours $minutes $seconds" -format "%H %M %S" -gmt 1]
			} else {
				file stat $videoFile fileStat
				set videoDate $fileStat(mtime)
				set videoDuration 0
			}
			
			lset videoFiles [lsearch -exact $videoFiles $videoFile] [list $videoFile $videoDate $videoDuration]
			
			puts -nonewline " [file tail $videoFile]"
			flush stdout
		}
		puts " \]"
		
		# Order video files by creation timestamp
		foreach videoFile [lsort -dictionary -increasing -index 1 $videoFiles] {
			# Group videos within same time frame
			set videoYear [clock format [lindex $videoFile 1] -format "%Y"]
			set videoMonth [clock format [lindex $videoFile 1] -format "%m"]
			set videoDay [clock format [lindex $videoFile 1] -format "%d"]
			set videoHour [clock format [lindex $videoFile 1] -format "%H"]
			set previousDay [clock format [clock scan "$videoYear $videoMonth [expr [scan $videoDay %d] - 1]" -format "%Y %m %d"] -format "%Y%m%d"]
			
			if { [llength [array names dailyVideos -exact $previousDay]] &&  [expr [scan $videoHour %d] < [scan $DAY_RESET %d]]} {
				# Video created before day+1 05:59:59 (DAY_RESET)
				lappend dailyVideos($previousDay) [list [file normalize [lindex $videoFile 0]] [lindex $videoFile 1] [lindex $videoFile 2]]
			} else {
				lappend dailyVideos([clock format [lindex $videoFile 1] -format "%Y%m%d"]) [list [file normalize [lindex $videoFile 0]] [lindex $videoFile 1] [lindex $videoFile 2]]
			}
		}
		
		if { [llength $videoFiles] } {
			# Generate "join" file for multiple videos an a day
			puts "Generating \"join\" files for multi-file videos"
		}

		foreach dailyVideo [lsort [array names dailyVideos]] {
			set previousTime -1
			
			# Process main and respective split files
			foreach videoFile $dailyVideos($dailyVideo) {
				# If single file, does not need to be stitched
				if { [llength $dailyVideos($dailyVideo)] == 1 } {
					puts "Date: [clock format [lindex $videoFile 1] -format "%Y-%m-%d %T"] \[ [file tail [lindex $videoFile 0]] \]"
					break
				} else {
					# Create "join" file using first video as reference
					if { $previousTime == -1 } {
						set previousTime 0
						set joinFilename [file join $GOPRO_HOME $JOINED_VIDEOS "${dailyVideo}.txt"]
						set joinFile [open $joinFilename w]
						
						puts $joinFile "# [clock format [lindex $videoFile 1] -format "%Y-%m-%d %T"]"
						puts $joinFile "# File to be used with FFmpeg"
						puts $joinFile "# By 3dK©\n#"
						
						puts -nonewline "Date: [clock format [lindex $videoFile 1] -format "%Y-%m-%d"] \[ "
					}
					
					set previousTime [expr $previousTime + [lindex $videoFile 2]]
					
					puts $joinFile "file \'[lindex $videoFile 0]\'"
					puts $joinFile "# \[[clock format $previousTime -format "%Hh%Mm%Ss" -gmt 1]\]"
					
					puts -nonewline "[file tail [lindex $videoFile 0]] "
					flush stdout
				}
			}
			
			if { [llength $dailyVideos($dailyVideo)] == 1 } {
				# Single file video
				# 0: source 1: destination
				set dailyVideos($dailyVideo) [list [lindex $videoFile 0] [file join $GOPRO_HOME $JOINED_VIDEOS "${dailyVideo}.mp4"]]
			} else {
				# Multi file video
				# 0: join N: videos
				set dailyVideos($dailyVideo) [list $joinFilename {*}$dailyVideos($dailyVideo)]
				close $joinFile
				
				puts -nonewline "\]\n"
				puts "Join file for [clock format [clock scan $dailyVideo -format "%Y%m%d"] -format "%Y-%m-%d"] generated: [file tail $joinFilename]"
			}
			
			puts ""
		}

		# Join daily videos with FFmpeg or move with Rsync
		if { [llength [array names dailyVideos]] } {
			set pidList [list]
			
			foreach dailyVideo [lsort [array names dailyVideos]] {
				puts -nonewline "Processing daily video with "
				
				if { [llength $dailyVideos($dailyVideo)] > 2 } {
					# Multi file video, process with FFmpeg
					if { ![lindex [lindex $dailyVideos($dailyVideo) 1] 1] } {
						set videoDate [clock format [lindex [lindex $dailyVideos($dailyVideo) 1] 1] -format "%Y-%m-%dT%H:%M:%S"]
					} else {
						file stat [lindex [lindex $dailyVideos($dailyVideo) 1] 0] fileStat
						set videoDate $fileStat(mtime)
					}
					
					puts -nonewline "FFmpeg: [lindex $dailyVideos($dailyVideo) 0]"
					
					# dailyVideos 0: join N: videos
					set pid [eval exec $NICE $IONICE $FFMPEG -y -f concat -safe 0 -i [lindex $dailyVideos($dailyVideo) 0] -metadata "creation_time=$videoDate" -c copy [regsub {\.txt$} [lindex $dailyVideos($dailyVideo) 0] {.mp4}] >>& [regsub {\.txt$} [lindex $dailyVideos($dailyVideo) 0] {.log}] &]
					
					# dailyVideos: original videos
					foreach videoFile [lrange $dailyVideos($dailyVideo) 1 end] {
						lappend dailyVideos($pid) [lindex $videoFile 0]
					}
					
					# pidList 0: pid 1: destination video 2: start time
					lappend pidList [list $pid [regsub {\.txt$} [lindex $dailyVideos($dailyVideo) 0] {.mp4}] [clock seconds]]
				} else {
					# Single file video, move with Rsync
					puts -nonewline "Rsync: [lindex $dailyVideos($dailyVideo) end]"
					
					# dailyVideos 0: source 1: destination
					set pid [eval exec $NICE $IONICE $RSYNC -ahv [lindex $dailyVideos($dailyVideo) 0] [lindex $dailyVideos($dailyVideo) end] >>& [regsub {\.mp4$} [lindex $dailyVideos($dailyVideo) end] {.log}] &]
					
					# dailyVideos: original video
					set dailyVideos($pid) [lindex $dailyVideos($dailyVideo) 0]
					
					# pidList 0: pid 1: destination video 2: start time
					lappend pidList [list $pid [lindex $dailyVideos($dailyVideo) end] [clock seconds]]
				}
				
				array unset dailyVideos $dailyVideo
				
				puts " PID: $pid \[started on: [clock format [clock seconds] -format "%Y-%m-%d %T"]\]"
			}
		}
		puts ""
		
		if { [info exists pidList] } {
			while { [llength $pidList] } {
				after $SCAN_WAIT
				
				foreach pid $pidList {
					# Finished
					if { [catch { eval exec $PS -p [lindex $pid 0] >/dev/null } ] } {
						puts "Video file transfer finished: [lindex $pid 1] PID: [lindex $pid 0] \[[clock format [clock seconds] -format "%Y-%m-%d %T"]\] \[elapsed [formatTimeInterval [expr [clock seconds] - [lindex $pid 2]]]\]"
						lappend convertList [lindex $pid 1]
						
						puts "Deleting original video file(s): $dailyVideos([lindex $pid 0])"
						file delete {*}$dailyVideos([lindex $pid 0])
						
						set pidList [lsearch -all -inline -not -exact $pidList $pid]
					}
				}
				
				flush stdout
			}
			
			puts ""
		}
		
		# When finished, call convert script if in auto mode
		switch -nocase -- [lindex $argv 0] {
			"auto" {
				if { [info exists convertList] } {
					if { [llength $convertList] } {
						puts "Calling [file tail [info script]] auto convert $convertList"
						catch { eval exec [file normalize [info script]] "auto" "convert" {*}$convertList 2>@ stderr >@ stdout }
					}
				} else {
					puts "No videos were joined"
				}
			}
			
			default {
				puts "Run \"[file tail [info script]] manual convert\" to convert joined video(s)"
			}
		}
	}
	
	"convert" {
		# Script to convert video files with FFmpeg
		if { $argc > 2 } {
			puts -nonewline "Parse user/system specified files: "
			
			foreach videoFile [lrange $argv 2 end] {
				if { [file exists $videoFile] } {
					# Full path
					lappend videoFiles [file normalize $videoFile]
				} else {
					# Filename only
					lappend videoFiles [lsort -nocase [glob -nocomplain -dir [file join $GOPRO_HOME $JOINED_VIDEOS] -types f -- $videoFile]]
				}
				
				# If added file doesn't exist, remove from list
				if { ![file exists [lindex $videoFiles end]] } {
					set videoFiles [lrange $videoFiles 0 end-1]
				}
			}
			
			puts -nonewline "[llength $videoFiles] \[ "
		} else {
			puts "Parse all video files"
			
			set videoFiles [lsort -nocase [glob -nocomplain -dir [file join $GOPRO_HOME $JOINED_VIDEOS] -types f -- "*.mp4"]]
			
			puts -nonewline "Processing main video files with \"*.mp4\" extension: "
			puts -nonewline "[llength $videoFiles] \[ "
		}

		foreach videoFile $videoFiles {
			if { ![file isfile $videoFile] } {
				set videoFiles [lsearch -all -inline -not -exact $videoFiles $videoFile]
				continue
			}
			
			puts -nonewline "[file tail $videoFile] "
			flush stdout
		}
		puts "\]\n"

		# Convert previously collected files
		if { [llength $videoFiles] } {
			set pidList [list]
			
			foreach videoFile $videoFiles {
				puts -nonewline "Processing daily video: $videoFile"
				set outputFile [file join $GOPRO_HOME $CONVERTED_VIDEOS [file tail $videoFile]]
				
				set pid [eval exec $NICE $IONICE $FFMPEG -y -i $videoFile -c:a copy -c:v libx264 -preset veryfast -crf 26 $outputFile >>& [regsub {\.mp4$} $outputFile {.log}] &]
				
				# pidList 0: PID 1: Source 2: Output 3: Start Time
				lappend pidList [list $pid $videoFile $outputFile [clock seconds]]
				
				puts " PID: $pid \[[clock format [clock seconds] -format "%Y-%m-%d %T"]\]"
			}
		}
		puts ""

		# Remove old files upon finish
		if { [info exists pidList] } {
			while { [llength $pidList] } {
				after $SCAN_WAIT
				
				foreach pid $pidList {
					if { [catch { eval exec $PS --no-headers -q [lindex $pid 0] } ] } {
						# Finished
						puts "Video file conversion finished: [lindex $pid 2] PID: [lindex $pid 0] \[[clock format [clock seconds] -format "%Y-%m-%d %T"]\] \[elapsed [formatTimeInterval [expr [clock seconds] - [lindex $pid 3]]]\]"
						set pidList [lsearch -all -inline -not -exact $pidList $pid]
						
						puts "Deleting video file: [lindex $videoFiles [lsearch -exact $videoFiles [lindex $pid 1]]]"
						file delete [lindex $pid 1]
						
						if { [file exists [regsub {\.mp4$} [lindex $pid 1] {.txt}]] } {
							set textFile [regsub {\.mp4$} [lindex $pid 2] {.txt}]
							puts "Moving text file to: $textFile"
							file rename [regsub {\.mp4$} [lindex $pid 1] {.txt}] $textFile
						}
					} else {
						# Running
						continue
					}
				}
				
				flush stdout
			}
			
			# Send push notification to PUSH_DEVICE
			pushNotification $PUSH_DEVICE "GoPro Videos ([llength $videoFiles]) have been converted"
		}
	}
	
	default {
		puts "Unknown command \"[lindex $argv 1]\". Exiting"
		exit
	}
}

puts "\nScript \"[file tail [info script]] [lindex $argv 0] [lindex $argv 1]\" finished on: [clock format [clock seconds] -format "%Y-%m-%d %T"] \[elapsed [formatTimeInterval [expr [clock seconds] - $scriptTime]]\]"