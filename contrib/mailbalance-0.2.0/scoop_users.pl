#!/usr/bin/perl 

open(PASSWD, '/etc/passwd');
    while (<PASSWD>) {
        chomp;
        ($username, $passwd, $uid, $gid,
         $gcos, $home, $shell) = split(/:/);
	if ($uid >= 1000){
	   if ( /\/home/ ){
		$home =~ s/\/home\///g;
	   	print "$home ";

		}
        }
}  
