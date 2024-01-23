# Introduction

The media Chart hosts a number of applications used to download, organize and managed media.
This can include movies, tv shows, software, music and books.

The applications used are:
* transmission with openvpn
* prowlarr
* sonarr
* radarr

## Transmission with OpenVpn
Transmission is the torrent client and does the actuall downloading. OpenVpn creates a OpenVpn
connection while the downloading is happening. If the VPN connection is closed, then a kill
switch is activated on transmission and it will shut down. Once the VPN connection is established again
then the downloading will continue.

## Prowlarr
Torrent files are indexed on websites called `Indexers`. Prowlarr is an application which manages
your `Indexers`. When you have a site that you would like to use to search for content, you can add
it to `prowlarr`.

## Sonarr
`Sonarr` is an application that is used to manage your TV show content. You can use `Sonarr` to search
for TV shows.

`Sonarr` should be linked with `Prowlarr`. Once this is done, when you search for a TV show
using `Sonarr`, that search is sent to `Prowlarr`, which then searches for the TV show in all the `Indexers`,
that have been added to it.

`Sonarr`, should also be linked to `Transmission`. Once this is done, when `Prowlarr` finds a torrent link, it will
be sent back to `Sonarr`, `Sonarr` will then send this to `Transmission` to perform the actual download.

`Sonarr`, can also be used to rename and correctly catalogue your TV shows, so that they are moved to the
correct folder once they have been downloaded, and get updated with the correct naming convention.

## Radarr
`Radarr` works the same as `Sonarr` but is used for movies instead of TV shows. It integrates with `Prowlarr
`and `Transmission` in the same way.

# Network considerationns
Because some of the applications will need to contact others, we need to ensure the following:
* `Sonarr` can reach `Transmission`.
* `Sonarr` can reach `Prowlarr`.
* `Prowlarr` can reach `Sonarr`.

# Media Files
All media files will be stored on a NAS server in the media directory. Within this directory
we will also split the files into these directories:
* TV Shows
* Movies
* Music
* Software
* Books

TV show's will be further broken down like this:
* TV Show Name
    * Season 1
        * TV Show Name S01E01
        ...
    * Season 2
        * TV Show Name S02E01
        ...

Initially, all TV shows, Movies etc, will be downloaded into a directory called downloads.
After the download has completed the content will be moved to the appropriate directory and
renamed.

## Access Rights
On the NAS server, `Transmission`, `Sonarr` and `Radarr` will have read/write access. `Prowlarr` should
not require any access on the NAS server.



