#!/usr/bin/tclsh8.6

set summary [open "comparison.csv" w]

puts $summary "Codec,Preset,CRF,Time,Size"
puts $summary "-,Original,-,-,[file size reference.mp4]"
puts "-\tOriginal\t-\t-\t[file size reference.mp4]"

foreach codec [list "x264" "x265"] {
	foreach preset [list "ultrafast" "superfast" "veryfast" "faster" "fast" "medium"] {
		switch $codec {
			"x264" { set crfList [list 17 20 23 26 29] }
			"x265" { set crfList [list 21 25 28 31 34] }
		}
		
		foreach crf $crfList {
			set fileName "${codec}_${preset}_${crf}.mp4"
			set startTime [clock seconds]
			
			#catch [eval exec -ignorestderr /usr/bin/ffmpeg -y -hwaccel vaapi -vaapi_device /dev/dri/renderD128 -i "reference.mp4" -c:a copy -c:v lib${codec} -preset $preset -crf $crf $fileName]
			catch [eval exec -ignorestderr /usr/bin/ffmpeg -y -i "reference.mp4" -c:a copy -c:v lib${codec} -preset $preset -crf $crf $fileName]
			
			set finishTime [clock seconds]
			set time [expr $finishTime - $startTime]
			set size [file size $fileName]
			
			puts $summary "${codec},${preset},${crf},${time},${size}"
			puts "${codec}\t${preset}\t${crf}\t${time}\t${size}"
		}
	}
}

close $summary
