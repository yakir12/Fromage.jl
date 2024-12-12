using BinDeps

basedir = @__DIR__()

const urls = (linux = "https://exiftool.org/Image-ExifTool-13.07.tar.gz",
              apple = "https://exiftool.org/ExifTool-13.07.pkg",
              windows = "https://exiftool.org/exiftool-13.07_64.zip")

program = "exiftool"

if Sys.isunix()
    file = "Image-ExifTool-13.06"
    extension = ".tar.gz"
    binary_name = target = program
end

if Sys.iswindows()
    file = "exiftool-13.06"
    extension = ".zip"
    binary_name = "$program.exe"
    target = "exiftool(-k).exe"
end

filename = file*extension
url = "http://www.sno.phy.queensu.ca/~phil/exiftool/$filename"

if Sys.isunix()
    run(
        @build_steps begin
        FileDownloader(url, joinpath(basedir, "downloads", filename))
        CreateDirectory(joinpath(basedir, "src"))
        FileUnpacker(joinpath(basedir, "downloads", filename), joinpath(basedir, "src"), "")
        end
       )
    mv(joinpath(basedir, "src", file), joinpath(basedir, "src", "exiftool"), force = true)
end

if Sys.iswindows()
    run(
        @build_steps begin
        FileDownloader(url, joinpath(basedir, "downloads", filename))
        CreateDirectory(joinpath(basedir, "src"))
        FileUnpacker(joinpath(basedir, "downloads", filename), joinpath(basedir, "src"), target)
        CreateDirectory(joinpath(basedir, "src", "exiftool"))
        end
       )
    mv(joinpath(basedir, "src", target), joinpath("src", "exiftool", binary_name), force = true)
end

