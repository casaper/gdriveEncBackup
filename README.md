# gdriveEncBackup

* creates incremental Tar backup
* encrypts it with GnuPG
* creates PAR2 parity volumes for data safety
* uploads the gpg encrypted archive plus par2 sets to gDrive
* dumps all the information related to the backup as JSON to a dumpfile (for possible future use)

I created this for making my headless and unattended remote backups to Google Drive. Public Key encryption 
offers the benefit of having the files backed up stored strongly encrypted on Google Drive and no sensitive 
secret is stored on the headless machine either.

### Needs:

* [par2](http://parchive.sourceforge.net/ "Project page")
* [gdrive](https://github.com/prasmussen/gdrive "Project page")
* [GnuPG](https://www.gnupg.org/ "Project page")
* [Google Drive](https://www.google.com/intl/en/drive/ "Welcome page")

Tested only on Ubuntu Thrusty.
