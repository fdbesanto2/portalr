#' @importFrom graphics plot
#' @importFrom stats aggregate
#' @importFrom utils download.file read.csv unzip read.table tail

#' @title Full Path
#' @description Return normalized path for all operating systems
#' @param reference_path a path to join with current working directory
#' @param base_path Current working directory else path given
#'
#' @return Full path
#'
#' @examples
#' full_path('PortalData/Rodents/Portal_rodent.csv')
#' full_path('PortalData/Rodents/Portal_rodent.csv', '~')
#'
#' @noRd
full_path <- function(reference_path, base_path = getwd()) {
  base_path <- normalizePath(base_path)
  path <- normalizePath(file.path(base_path, reference_path), mustWork = FALSE)
  return(path)
}

#' @title Download the PortalData repo
#'
#' @description This downloads the latest portal data regardless if they are
#'   actually updated or not.
#'   TODO: incorporate data retriever into this when it's pointed at the github repo
#' @param base_folder Folder into which data will be downloaded
#' @param version Version of the data to download (default = "latest")
#' @inheritParams get_data_versions
#'
#' @return None
#'
#' @examples
#' \donttest{
#'   download_observations()
#'   download_observations("~/old-data", version = "1.50.0")
#' }
#'
#' @export
download_observations <- function(base_folder = "~", version = "latest", from_zenodo = FALSE)
{
  # only use zenodo if version == "latest"
  if (version != "latest")
    from_zenodo <- FALSE

  # get version info
  releases <- get_data_versions(from_zenodo = from_zenodo, halt_on_error = TRUE)

  # match version
  if (version == "latest")
  {
    match_idx <- 1
  } else {
    # Normalize version number
    if (grepl("^[0-9]+\\.[0-9]+$", version))
    {
      version <- paste0(version, ".0")
    }
    if (!grepl("^[0-9]+\\.[0-9]+\\.0$", version))
    {
      stop("Invalid version number; given, ", version, call. = FALSE)
    }

    match_idx <- match(version, releases$version)
    if (length(match_idx) != 1 || is.na(match_idx))
    {
      stop("Did not find a version of the data matching, ", version, call. = FALSE)
    }
  }

  # Attemt to download the zip file
  message("Downloading version ", releases$version[match_idx], " of the data...")
  zip_download_path <- releases$zipball_url[match_idx]
  zip_download_dest <- full_path("PortalData.zip", tempdir())
  download.file(zip_download_path, zip_download_dest, quiet = TRUE, mode = "wb")

  final_data_folder <- full_path("PortalData", base_folder)

  # Clear out the old files in the data folder without doing potentially dangerous
  # recursive deleting.
  if (file.exists(final_data_folder)) {
    old_files <- list.files(
      final_data_folder,
      full.names = TRUE,
      all.files = TRUE,
      recursive = TRUE,
      include.dirs = FALSE
    )
    file.remove(normalizePath(old_files))
    unlink(final_data_folder, recursive = TRUE)
  }

  #Github serves this up with the -master extension. Unzip and rename to remove that.
  primary_data_folder <- unzip(zip_download_dest, list = TRUE)$Name[1]
  unzip(zip_download_dest, exdir = base_folder)
  Sys.sleep(10)
  file.remove(zip_download_dest)
  file.rename(full_path(primary_data_folder, base_folder), final_data_folder)
}

#' @title get version and download info for PortalData
#'
#' @description Check either Zenodo or GitHub for the version and download link
#'   for PortalData.
#'
#' @param from_zenodo logical; if `TRUE`, get info from Zenodo, otherwise GitHub
#' @param halt_on_error logical; if `FALSE`, return NULL on errors, otherwise
#'   whatever got returned (could be an error or warning)
#' @return A data.frame with two columns, `version` (string with the version #) and
#'   `zipball_url` (download URLs for the corresponding zipped release).
#'
#' @export
get_data_versions <- function(from_zenodo = FALSE, halt_on_error = FALSE)
{
  releases   <- tryCatch(
    {
      if (from_zenodo)
      {
        get_zenodo_latest_release()
      } else {
        get_github_releases()
      }
    }
    ,
    error = function(e) {
      if (halt_on_error) {
        stop(e)
      } else {
        e
      }
     },
    warning = function(w) w
   )
  if (!is.data.frame(releases))
  {
    return(NULL)
  }
  return(releases)
}

#' @title get Zenodo download link for PortalData
#'
#' @description Check Zenodo for the link and version for the latest release of
#'   PortalData.
#'
#' @return A data.frame with two columns, `version` (string with the version #) and
#'   `zipball_url` (download URLs for the corresponding zipped release).
#'
#' @noRd
get_zenodo_latest_release <- function()
{
  # Try and parse the download link from Zenodo
  resp <- httr::GET("https://zenodo.org/record/1215988")
  if (httr::http_type(resp) != "text/html") # check for errors
  {
    stop("Zenodo response was not in text format", call. = FALSE)
  }
  page_content <- httr::content(resp, "text")
  match_pos <- regexec("https://zenodo.org/api/files/[0-9a-f\\-]+/weecology/[0-9a-zA-z.\\-]+zip",
                       page_content)
  match_text <- regmatches(page_content, match_pos)

  if (length(match_text) != 1 || length(match_text[[1]]) <= 0)
  {
    stop("Wasn't able to parse Zenodo for the download link.", call. = FALSE)
  }
  zip_download_path <- match_text[[1]][1]

  pattern <- "([0-9]+\\.[0-9]+\\.[0-9]+)\\.zip"
  match_pos <- regexec(pattern, zip_download_path)
  match_text <- regmatches(zip_download_path, match_pos)
  if (length(match_text) != 1 || length(match_text[[1]]) <= 0)
  {
    stop("Wasn't able to parse Zenodo for the version.", call. = FALSE)
  }

  return(data.frame(version = match_text[[1]][2],
                    zipball_url = zip_download_path,
                    stringsAsFactors = FALSE))
}

#' @title get GitHub Release Info for PortalData
#'
#' @description Use the GitHub API to get info about the releases of the
#'   PortalData repo.
#'
#' @return A data.frame with two columns, `version` (string with the version #) and
#'   `zipball_url` (download URLs for the corresponding zipped release).
#'
#' @noRd
get_github_releases <- function()
{
  pat <- Sys.getenv("GITHUB_PAT")
  if (identical(pat, ""))
  {
    github_auth <- NULL
  } else {
    github_auth <- httr::authenticate(pat, "x-oauth-basic", "basic")
  }

  ## try to get links to all versions from GitHub
  releases <- data.frame(tag_name = character(),
                         zipball_url = character())
  match_text <- "next"
  page_idx <- 1

  # keep getting info until no more `next` pages
  while (match_text == "next" || match_text == "last")
  {
    github_path <- paste0("https://api.github.com/repos/weecology/PortalData/releases?page=", page_idx)
    resp <- httr::GET(github_path, github_auth)

    # check if problems with retrieving info
    if (httr::headers(resp)$status == "403 Forbidden" &&
        httr::headers(resp)$"x-ratelimit-remaining" == "0") # rate limit exceeded
    {
      stop("Exceeded GitHub rate limit, please try again in an hour or consult the documentation for details.\n",
           "https://developer.github.com/v3/#rate-limiting")
    } else if (httr::http_type(resp) != "application/json") # check for errors
    {
      stop("GitHub response was not in JSON format", call. = FALSE)
    } else if (httr::headers(resp)$status == "401 Unauthorized"){
      stop("Bad GitHub credentials")
    }

    # extract release info
    releases <- rbind(releases,
                      jsonlite::fromJSON(httr::content(resp, "text"))[, c("tag_name", "zipball_url")])

    # update page count
    page_idx <- page_idx + 1

    # check for next page of results
    link_str <- httr::headers(resp)$link
    match_pos <- regexec("^<.+>; rel=\"([a-z]+)\", <.+>; rel=\"([a-z]+)\"$", link_str)
    match_text <- regmatches(link_str, match_pos)[[1]][2]
  }
  names(releases) <- c("version", "zipball_url")
  return(releases)
}

#' @title Check for latest version of data files
#' @description Check the latest version against the data that exists on
#'   the GitHub repo
#' @param base_folder Folder in which data will be checked
#'
#' @return bool TRUE if there is a newer version of the data online
#'
#' @export
check_for_newer_data <- function(base_folder = "~")
{
  # first see if the folder for the data files exist
  tryCatch(base_path <- file.path(normalizePath(base_folder, mustWork = TRUE), "PortalData"),
           error = function(e) stop("Unable to use the specified path: ", base_folder, call. = FALSE),
           warning = function(w) w)

  # check for `version.txt``
  version_file <- file.path(base_path, "version.txt")
  if (!file.exists(version_file)) # old version of data is missing this metadata file
    return(TRUE)

  pattern <- "([0-9]+)\\.([0-9]+)\\.([0-9]+)"
  version_str <- as.character(read.table(version_file)[1, 1])
  local_version <- c(as.numeric(gsub(pattern, "\\1", version_str)),
                     as.numeric(gsub(pattern, "\\2", version_str)),
                     as.numeric(gsub(pattern, "\\3", version_str)))

  # pull github version from list of releases
  github_releases <- get_data_versions(from_zenodo = FALSE)
  if (is.null(github_releases)) # if unable to access github releases
  {
    return(FALSE)
  }
  github_version_str <- github_releases$version[1]
  github_version <- c(as.numeric(gsub(pattern, "\\1", github_version_str)),
                      as.numeric(gsub(pattern, "\\2", github_version_str)),
                      as.numeric(gsub(pattern, "\\3", github_version_str)))

  if (github_version[1] > local_version[1])
    return(TRUE)

  if (github_version[1] == local_version[1] &&
      github_version[2] > local_version[2])
    return(TRUE)

  if (github_version[1] == local_version[1] &&
      github_version[2] == local_version[2] &&
      github_version[3] > local_version[3])
    return(TRUE)

  return(FALSE)
}