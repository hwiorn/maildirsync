#!/usr/bin/env perl

# #########################################################################
# Imports
# #########################################################################

use File::Basename;
use File::Copy qw(copy move);
use File::Path qw(mkpath);
use IO::Handle;
use IPC::Open2;
use Fcntl qw(SEEK_SET);
use UNIVERSAL qw(isa);
use strict;
use warnings;
require 5.006;

# #########################################################################
# Constants
# #########################################################################
my $VERSION = '1.2';
my $REVISION = q$Id$;
my $BASENAME = basename($0);
my $STATE_FILE_FIRST_LINE = "# maildirsync state file. ".
    "Do not edit unless you know what you are doing\n";

#   long name       type:default    short   source  target
my @OPTSPEC = (qw(
    recursive       b:0                 r       1       1
    backup          s                   b       0       1
    backup-tree     b:0                 B       0       1
    bzip2           s:bzip2             -       1       0
    gzip            s:gzip              -       1       0
    maildirsync     s:maildirsync.pl    -       1       1
    mode            i:0                 -       0       0
    rsh             s:ssh               R       0       0
    verbose         I:0                 v       1       1
    alg             ?id|md5:id          a       1       1
    delete-before   b:0                 d       0       1
    version         b                   V       0       0
    short-version   b                   -       0       0
    exclude         s:[]                x       1       1
    exclude-source  s:[]                -       1       0
    exclude-target  s:[]                -       1       0
    rename          s:[]                N       1       0
    destination	    ?win|lin:none       -       0       0
));

push @OPTSPEC,
    "rsh-sep",      "s: +",         "-",    0,      0;     

use constant SOURCE_MODE => "source";
use constant TARGET_MODE => "target";

# Commands
use constant DELETE_COMMAND => "DEL";
use constant NEW_COMMAND    => "NEW";
use constant END_COMMANDS   => "END";
use constant SEND_COMMAND   => "SEND";
use constant COMMIT_COMMAND => "COMMIT";
use constant COMMIT_OK      => "COMMIT_OK";
# file-data array members
use constant ID             => 0;
use constant IDSTORE        => 1;
use constant DATAH          => 2;

# #########################################################################
# Global variables
# #########################################################################

my $MODE = "startup";

our (%OPTHASH, %SHORT_OPTS, %OPT, @SOURCE_OPT, @TARGET_OPT);

# #########################################################################
# Subs
# #########################################################################

sub verbose ($$) { my ($verbosity_level, $message) = @_;
    print STDERR "$MODE: ".("  " x $verbosity_level)."$message\n" 
        if $OPT{verbose} >= $verbosity_level;
}

sub add_opt ($;$) { my ($optname, $value) = @_;
    exit_with_error("Invalid parameter: $optname") 
        if !$optname || !exists $OPTHASH{$optname};
    my ($type, $source_opt, $target_opt) = @{ $OPTHASH{$optname} };
    if ($type eq 's' || $type eq 'i') {
        $value = shift @ARGV if !defined $value;
    } elsif ($type eq 'b') {
        $value = 1;
    } elsif ($type eq 'I') { # increment
        $value = ($OPT{$optname} || 0)+1;
    } elsif (my ($regex) = $type =~ /^\?(.*)/) {
        $value = shift @ARGV if !defined $value;
        exit_with_error("Invalid parameter value: $optname: $value") if $value !~ /^$regex$/;
    }
    verbose 4 => "add option $optname = ".($value || "");
    if (!isa($OPT{$optname}, 'ARRAY')) {
        $OPT{$optname} = $value;
    } else {
        push @{$OPT{$optname}}, $value;
    }
    push @SOURCE_OPT, "--$optname=$value" if $source_opt;
    push @TARGET_OPT, "--$optname=$value" if $target_opt;
}

sub exit_with_error ($) { my ($error) = @_;
    die "$error\n";
}

sub source_mode ($$$$) { my ($rpipe, $wpipe, $path, $state_file) = @_;
    $MODE = SOURCE_MODE;
    my $oldfh = select $wpipe;
    verbose 1 => "Reading state file";
    my $state = read_state_file($state_file);

    verbose 1 => "Reading directory structure";
    my $filedata = read_filelist($path);
    my @old_files = sort keys %{$state->[ID] ||= {} };

    verbose 1 => "Calculating digest informations on old source files";
    foreach my $k (sort keys %{ $state->[ID] }) {
        add_store_state($state, $k, calc_store_state($path, $k,
            $filedata->[ID]->{$k} || $state->[ID]->{$k}))
                if !defined $state->[IDSTORE]->{$k} || !$state->[IDSTORE]->{$k};
    }

    verbose 1 => "Sending change / deletion requests";
    my %new_files = %{ $filedata->[ID] };
    my @to_be_deleted;
    foreach my $k (@old_files) {
        if (!exists $filedata->[ID]->{$k}) {
            push @to_be_deleted, $k;
            send_command($wpipe, DELETE_COMMAND, $k);
        } elsif ($filedata->[ID]->{$k} ne $state->[ID]->{$k}) {
            send_new_command($wpipe, $state, $filedata, $k);
        }
        delete $new_files{$k};
    }

    verbose 1 => "Calculating digest informations on new source files";
    my @new_files = sort keys %new_files;
    foreach my $k (@new_files) {
        my $store_state = calc_store_state($path, $k, $filedata->[ID]->{$k});
        add_store_state($state, $k, $store_state);
    }

    verbose 1 => "Sending new file requests";
    foreach my $k (@new_files) {
        send_new_command($wpipe, $state, $filedata, $k);
    }
    send_command($wpipe, END_COMMANDS);

    local $|=1;
    my @files_to_send;
    verbose 1 => "Waiting for answer";
    while (1) {
        my @cmd = receive_command($rpipe);
        last if $cmd[0] eq END_COMMANDS;
        die "Protocol error" if $cmd[0] ne SEND_COMMAND;
        my (undef, $fileid, $header_only) = @cmd;
        die "Invalid file to send" if !exists $filedata->[ID]->{$fileid};
        push @files_to_send, [ $fileid, $header_only ];
    }

    verbose 1 => "Sending files";
    foreach my $filed (@files_to_send) {
        my ($file, $header_only) = @$filed;
        send_file($wpipe, $path, $file, 
            $filedata->[ID]->{$file}, $header_only);
    }
    send_command($wpipe, COMMIT_COMMAND);
    my @cmd = receive_command($rpipe);
    if ($cmd[0] ne COMMIT_OK) {
        die "Cannot commit changes, bad answer from target: @cmd\n";
    }
    verbose 1 => "Saving state file";
    $state->[ID] = $filedata->[ID];
    save_state_file($state_file, $state);
    select $oldfh;
    verbose 1 => "Work Finished";
    close $rpipe;
    close $wpipe;
}

sub target_mode ($$$) { my ($rpipe, $wpipe, $path) = @_;
    $MODE = TARGET_MODE;
    my $oldfh = select $wpipe;
    verbose 1 => "Reading directory structure";
    my $filedata = read_filelist($path);
    my @files_to_get;
    my @files_to_delete;
    verbose 1 => "Waiting for changes";
    while (1) {
        my @cmd = receive_command($rpipe);
        my $command = shift @cmd;
        if ($command eq END_COMMANDS) {
            last;
        } elsif ($command eq DELETE_COMMAND) {
            my ($id) = @cmd;
            if (exists $filedata->[ID]->{$id}) {
                if ($OPT{"delete-before"}) {
                    delete_file($path, $filedata->[ID]->{$id})
                } else {
                    push @files_to_delete, $filedata->[ID]->{$id}
                }
            }
        } elsif ($command eq NEW_COMMAND) {
           my ($id, $data, $header_size, @copy_from) = @cmd;
            if (exists $filedata->[ID]->{$id}) { # already exists -> move
                change_file($path, $filedata->[ID]->{$id}, $data)
                    if $filedata->[ID]->{$id} ne $data;
            } else { # not exists
                my $copy_is_done;
                $copy_is_done ||= 
                    try_copy_body($path, $filedata->[ID]->{$_}, $data, $header_size)
                        foreach @copy_from;
                push @files_to_get, [ $id, $data, ($copy_is_done ? 1 : 0)];
            }
        } else {
            die "Unknown command received: $command @cmd";
        }
    }
    verbose 1 => "Sending back file-requests";
    foreach my $f (@files_to_get) {
        send_command($wpipe, SEND_COMMAND, $f->[0], $f->[2]);
    }
    send_command($wpipe, END_COMMANDS);
    local $|=1;
    verbose 1 => "Receiving files";
    foreach my $f (@files_to_get) {
        receive_file($rpipe, $path, $f->[0], $f->[1], $f->[2]);
    }
    verbose 1 => "Committing changes";
    my @cmd = receive_command($rpipe);
    die "Protocol error" if $cmd[0] ne COMMIT_COMMAND;
    delete_file($path, $_) foreach @files_to_delete;
    send_command($wpipe,COMMIT_OK);
    verbose 1 => "Work finished";
    select $oldfh;
}

my $listfile_perms;

sub read_state_file ($) { my ($filename) = @_;
    my $FH;
    my $state_data = [];
    $state_data->[ID] = {};
    $state_data->[IDSTORE] = {};
    $state_data->[DATAH] = {};
    verbose 1 => "reading state file $filename";
    $listfile_perms = 0666 ^ umask();
    return $state_data if ! -e $filename;
    if ($filename =~ /\.bz2/) {
        my $pid = open $FH, "-|";
        if (!$pid) { # child
            exec($OPT{bzip2}, "-cd", $filename);
            exit(1);
        }
    } elsif ($filename =~ /\.gz$/) {
        my $pid = open $FH, "-|";
        if (!$pid) { # child
            exec($OPT{gzip}, "-cd", $filename);
            exit(1);
        }
    } else { open $FH, $filename };
    return $state_data if !$FH; # no state-file
    $listfile_perms = (stat($filename))[2] & 07777;
    my $first_line = <$FH>;
    exit_with_error("Invalid state file header: $first_line")
        if $first_line ne $STATE_FILE_FIRST_LINE;
    while (<$FH>) {
        chomp;
        next if /^$/;
        my ($id, $state, $store_state) = split /\t/;
        exit_with_error("Invalid line in the state file: $_") if !$id;
        my $dirname = dirname($state);
        if (!match_excludes($dirname)) {
            $state_data->[ID]->{$id} = $state;
            add_store_state($state_data, $id, $store_state);
        }
    }
    close $FH;
    return $state_data;
}

sub read_directory ($$$;$) { my ($basepath, $path, $aref, $mailsubdir) = @_;
    my $dirpath = "$basepath$path";
    if (match_excludes($path)) {
        verbose 3 => "Excluding directory: $dirpath";
        return;
    }
    verbose 3 => "Reading directory: $dirpath";
    opendir DIR, $dirpath or return;
    my @entries = readdir(DIR);
    closedir DIR;
    foreach my $e (@entries) {
        my $entry = "$dirpath/$e";
        next if $e =~ /^\.(\.)?$/; # . , ..
        if (!$mailsubdir && -d $entry) {
            next if $e eq 'tmp';
            my $newmailsubdir = $e eq 'new' || $e eq 'cur';
            if ($newmailsubdir || $OPT{recursive}) {
                no warnings;
                read_directory($basepath, "$path/$e", $aref, $newmailsubdir);
            }
        }
        if ($mailsubdir && -f $entry) {
            my ($key, $filedata) = pack_filedata("$path/$e");
            if ($key) { # valid file
                verbose 1 => "Duplicated file id entry: $key" if exists $aref->[ID]->{$key};
                $aref->[ID]->{$key} = $filedata;
            }
        }
    }
}

sub read_filelist ($) { my ($path) = @_;
    my @file_data;
    $file_data[ID] = {};
    read_directory($path, "", \@file_data);
    return \@file_data;
}

sub send_command ($@) { my ($channel, @command) = @_;
    verbose 4 => "sending command: @command";
    print $channel join("\t", @command)."\n" or
        exit_with_error("Cannot send command: @command: $!");
}

sub send_file_data ($$$) { my ($channel, $file_name, $header_only) = @_;
    my $FILE;
    if (open $FILE, $file_name) {
        my $file_header = read_header($FILE);
        my $size_to_send = length($file_header);
        $size_to_send = (-s $FILE) if !$header_only;
        print $channel $size_to_send."\n" 
            or exit_with_error("Cannot send size header");
        print $channel $file_header;
        if (!$header_only) {
            print or exit_with_error("Cannot send file header") while <$FILE>;
        }
        close $FILE;
    } else {
        print "-1\n";
    }
}

sub receive_file_data ($$$) { my ($channel, $file_name, $header_only) = @_;
    my $length = <$channel>;
    chomp $length;
    my $data;
    my $FILE;
    return 0 if $length == -1;
    verbose 5 => "File length: $length";
    mkdir_for_target_file($file_name);
    my $opened = open $FILE, ($header_only ? "+<" : ">"), $file_name;
    seek($FILE, 0, SEEK_SET) if $header_only && $opened;
    warn "Cannot open file $file_name for writing: $!" if !$opened;
    while ($length >0)  {
        my $bytes_read = read $channel, $data, ($length > 4096 ? 4096 : $length) or
            exit_with_error("Cannot receive file (length: $length)");
        print $FILE $data if $opened;
        $length -= $bytes_read;
    }
    close $FILE if $opened;
    return 1; 
}

sub receive_command ($) { my ($channel) = @_;
    my $command = <$channel>;
    defined($command) or exit_with_error("Cannot read command from pipe");
    chomp $command;
    my @command = split /\t/, $command;
    verbose 4 => "command received: @command";
    return @command;
}

sub save_state_file ($$) { my ($filename, $statedata) = @_;
    my $FH;
    my $newfilename = $filename.".new.$$";
    my $statedir = dirname($newfilename);
    unless (-d $statedir) {
        mkpath($statedir)
            or exit_with_error("Cannot create directory for state file: $statedir: $!");
        verbose 3 => "created directory: $statedir";
    }
    if ($filename =~ /\.bz2$/) {
        my $pid = open $FH, "|-";
        if (!$pid) { # child
            open STDOUT, ">" ,$newfilename or exit 1;
            exec($OPT{bzip2});
            exit(1);
        }
    } elsif ($filename =~ /\.gz$/) {
        my $pid = open $FH, "|-";
        if (!$pid) { # child
            open STDOUT, ">", $newfilename or exit 1;
            exec($OPT{gzip});
            exit(1);
        }
    } else { open $FH, ">", $newfilename or $FH = undef };
    exit_with_error("Cannot open temporary state file for writing: $newfilename") if !$FH;
    print $FH $STATE_FILE_FIRST_LINE;
    print $FH join("\t",$_, $statedata->[ID]->{$_}, ($statedata->[IDSTORE]->{$_} || ""))."\n"
        foreach keys %{$statedata->[ID]};
    close $FH;
    chmod $listfile_perms, $newfilename
        or exit_with_error("Cannot chmod temporary state file: $!");
    if (-f $filename) {
        move $filename, $filename."~"
            or exit_with_error("Cannot make backup of $filename: $!");
    }
    move $newfilename, $filename
        or exit_with_error("Cannot move temporary state file $filename: $!");
    if (-f $filename."~") {
        unlink $filename."~"
            or exit_with_error("Cannot unlink backup state file: $filename: $!");
    }
}

my $backup_dir_created = 0;

sub delete_file ($$) { my ($basepath, $filedata) = @_;
    my ($path) = unpack_filedata($filedata);
    if ($OPT{backup}) {
        my $dest = $OPT{backup};
        if ($OPT{'backup-tree'}) {
            $dest .= $path;
            mkdir_for_target_file($dest);
        } else {
            mkpath($dest) if !$backup_dir_created++;
        }
        verbose 2 => "Deleting file: $path (moving to backup directory)";
        move "$basepath$path", $dest
            or warn "Cannot move $path to the backup directory: $!\n" ;
    } else {
        verbose 2 => "Deleting file: $path";
        unlink "$basepath$path" or warn "Cannot unlink $path: $!\n"
    }
}

sub change_file ($$$) { my ($basepath, $filedata1, $filedata2) = @_;
    my ($path1) = unpack_filedata($filedata1);
    my ($path2) = unpack_filedata($filedata2);
    mkdir_for_target_file("$basepath$path2");
    verbose 2 => "Move file from $path1 to $path2";
    move "$basepath$path1", "$basepath$path2" or 
        warn "Cannot move $path1 to $path2: $!\n";
}

sub send_file ($$$$$) { my ($wpipe, $basepath, $file, $filedata, $header_only) = @_;
    my ($path) = unpack_filedata($filedata);
    verbose 2 => "Sending file".($header_only ? " (header only)" : "").": $path";
    send_file_data($wpipe, "$basepath$path", $header_only);
}

sub receive_file ($$$$$) { my ($rpipe, $basepath, $file, $filedata, $header_only) = @_;
    my ($path) = unpack_filedata($filedata);
    verbose 2 => "Receiving file".($header_only ? " (header only)" : "").": $path";
    my $target_name = "$basepath$path";
    if($OPT{destination} eq 'win') {$target_name =~ s/\:/&#58;/g;}
    elsif($OPT{destination} eq 'lin') {$target_name =~ s/&#58;/\:/g;}
    my $temp_name = $target_name;
    $temp_name =~ s{^(.*)(?:new|cur)(/.*)$}{$1tmp/$2};
    if($OPT{destination} eq 'win') {$temp_name =~ s/\:/&#58;/g;}
    elsif($OPT{destination} eq 'lin') {$temp_name =~ s/&#58;/\:/g;}
    receive_file_data($rpipe, $temp_name, $header_only)
        or return; # No files received: nothing to do
    mkdir_for_target_file($target_name);
    rename $temp_name, $target_name
        or warn "Cannot rename the temporary file $temp_name to target $target_name";
}

sub unpack_filedata ($) { my ($filedata) = @_;
    return ($filedata);
}

sub pack_filedata ($) { my ($path) = @_;
    my ($message_id) = $path =~ m{.*/([^\.\:/][^\:/]*?)(?:(?:\:|&#58;)(?:1|2),[^/]*)?$}
        or return (); # not valid
    $message_id =~ m{&#58;} and return (); # not valid
    return ($message_id, "$path");
}

my %MKDIR_HASH;

sub mkdir_for_target_file ($) { my ($filename) = @_;
    my $dirname = dirname($filename);
    $dirname =~ s/(new|cur|tmp)\/?$//;
    no warnings;
    return if $MKDIR_HASH{$dirname}++;
    verbose 3 => "Creating directory tree: $filename";
    mkpath($dirname."/new");
    mkpath($dirname."/tmp");
    mkpath($dirname."/cur");
}

sub add_store_state ($$$) { my ($state_data, $id, $store_state) = @_;
    return if !$store_state;
    my ($header_data, $data_hash) = unpack_store_state($store_state);
    $state_data->[IDSTORE]->{$id} = $store_state;
    push @{ $state_data->[DATAH]->{$data_hash} }, $id;
}

sub unpack_store_state ($) { my ($store_state) = @_;
    return $store_state =~ /^(.*)-(.*)$/;
}

sub calc_store_state ($$$) { my ($basepath, $id, $filedata) = @_;
    return undef if $OPT{alg} ne "md5";
    my ($path, undef) = unpack_filedata($filedata);
    my $md5 = Digest::MD5->new;
    open my $FH, "$basepath$path" or return undef;
    my $str = read_header($FH);
    my $header_data = length($str);
    $md5->addfile($FH);
    my $data_hash = $md5->hexdigest.((-s $FH) - length($str));
    my $return_data = "$header_data-$data_hash";
    close $FH;
    verbose 2 => "Calculated data for file $id: $return_data";
    return $return_data;
}

sub send_new_command ($$$$) { my ($wpipe, $state, $filedata, $k) = @_;
    my ($header_size, $data, %datahash) = (0);
    if (my $hash = $state->[IDSTORE]->{$k}) {
        ($header_size, $data) = unpack_store_state($hash);
        $datahash{$_} = 1 
            foreach @{ $state->[DATAH]->{$data} || [] };
    }
    delete $datahash{$k};
    send_command($wpipe, NEW_COMMAND, $k, rename_file_in_filedata($filedata->[ID]->{$k}),
        $header_size, keys %datahash);
}

sub read_header { my ($FH) = @_;
    my $str = "";
    while (<$FH>) {
        $str .= $_;
        last if /^$/;
    }
    return $str;
}

sub try_copy_body ($$$$) { my ($basepath, $source_data, $target_data, $header_size) = @_;
    return if !$source_data;
    my ($source_path, undef) = unpack_filedata($source_data);
    return if $header_size == 0;
    verbose 3 => "Trying to copy body from message: $source_path, header_size: $header_size";
    my $FILE;
    open $FILE, "$basepath$source_path" and do { # the source file exists
        read_header($FILE); # we skip the original header
        my ($target_path, undef) = unpack_filedata($target_data);
        my $target_temp_file = "$basepath$target_path";
        $target_temp_file =~ s{^(.*)(?:new|cur)(/.*)$}{$1tmp/$2};
        mkdir_for_target_file($target_temp_file);
        open my $OFILE, ">$target_temp_file" 
            or do { warn "Cannot open temp file for output"; return 0 };
        seek($OFILE, $header_size, SEEK_SET);
        my ($buffer, $bytes_read);
        while (($bytes_read = read($FILE, $buffer, 4096)) > 0) {
            print $OFILE substr($buffer, 0, $bytes_read);
        }
        if (!defined $bytes_read) {
            warn "Cannot copy source file $source_path to $target_temp_file: $!\n"; 
            return 0
        }
        verbose 2 => "File body for $target_path is copied from $source_path";
        close $OFILE;
        close $FILE;
        return 1;
    };
    return 0;
}

sub match_excludes ($) { my ($path) = @_;
    my $local_source = $MODE eq SOURCE_MODE ? $OPT{"exclude-source"} : $OPT{"exclude-target"};
    foreach my $exclude (@{ $OPT{exclude} }, @$local_source) {
        return 1 if $path =~ /$exclude/;
    }
    return 0;
}

sub rename_file_in_filedata ($) { my ($filedata) = @_;
    ($_) = unpack_filedata($filedata);
    foreach my $rename (@{ $OPT{rename} }) {
        eval $rename;
        exit_with_error("Error running command '$rename' on '$_'. Error: '$@'") if $@;
    }
    $filedata = pack_filedata($_);
}

# #########################################################################
# Main program
# #########################################################################

while (@OPTSPEC) {
    my $optname                         = shift @OPTSPEC;
    my ($type, $default)    = shift(@OPTSPEC) =~ /^(.+?)(?:\:(.*))?$/;
    my $shortname                       = shift @OPTSPEC;
    my $source_opt                      = shift @OPTSPEC;
    my $target_opt                      = shift @OPTSPEC;
    $OPTHASH{$optname} = [$type, $source_opt, $target_opt];
    if (defined $default && $default eq '[]') {
        $OPT{$optname} = [];
    } else {
        $OPT{$optname} = $default;
    }
    $SHORT_OPTS{$shortname} = $optname if $shortname ne '-';
}

while (@ARGV) {
    my $arg = shift @ARGV;
    last if $arg eq '--';
    if (my ($optname, $optval) = $arg =~ /^--([\w-]+)(?:\=(.*))?/) {
        add_opt($optname, $optval);
    } elsif (my ($short_opts) = $arg =~ /^-(\w+)/) {
        add_opt($SHORT_OPTS{$_}) foreach split //, $short_opts;
    } else {
        unshift @ARGV, $arg;
        last;
    }
}

if ($OPT{version}) {
    print "$BASENAME version $VERSION, revision: $REVISION\n\n";
    print "Type perldoc $BASENAME for help\n\n";
    exit 0;
}

if ($OPT{"short-version"}) {
    print "$VERSION\n";
    exit 0;
}

# managing the source and target modes 

$SIG{PIPE} = sub { };

if ($OPT{alg} eq 'md5') {
    eval { require Digest::MD5 };
    exit_with_error("Digest::MD5 module is required for md5 algorithm") 
        if !$INC{"Digest/MD5.pm"};
}

verbose 1 => "Starting source and target modes";

if ($OPT{mode} eq 'source') { # source pipe mode
    my ($srcpath, $state) = @ARGV;
    source_mode(\*STDIN, \*STDOUT, $srcpath, $state);
} elsif($OPT{mode} eq 'target') { # target pipe mode
    my ($trgpath) = @ARGV;
    target_mode(\*STDIN, \*STDOUT, $trgpath);
} else {
    exit_with_error("Usage: $BASENAME [options] src target state-file") if @ARGV != 3;
    my ($src, $trg, $state_file) = @ARGV;
    my ($srchost, $srcpath) = $src =~ /^(?:(.*?)\:)?(.*)/;
    my ($trghost, $trgpath) = $trg =~ /^(?:(.*?)\:)?(.*)/;
    my @rsh_command = split /$OPT{"rsh-sep"}/, $OPT{rsh};
    # verbose 0 => "Rsh command: ".join(",",@rsh_command);
    if (defined $srchost && defined $trghost) {
        exit_with_error("Source or destination must be local");
    } elsif (defined $srchost) {
        my ($pipei, $pipeo);
        open2($pipei, $pipeo, @rsh_command, $srchost,
            $OPT{maildirsync}, "--mode=source", @SOURCE_OPT, $srcpath, $state_file);
        target_mode($pipei, $pipeo, $trgpath);
    } elsif (defined $trghost) {
        my ($pipei, $pipeo);
        open2($pipei, $pipeo, @rsh_command, $trghost,
            $OPT{maildirsync}, "--mode=target", @TARGET_OPT, $trgpath);
        source_mode($pipei, $pipeo, $srcpath, $state_file);
    } else {
        pipe(\*P1A, \*P1B);
        pipe(\*P2A, \*P2B);
        my $oldfh = select(P1B);
        $|=1; 
        select(P2B);
        $|=1; 
        select($oldfh);
        if (fork()) {
            source_mode(\*P1A, \*P2B, $srcpath, $state_file);
        } else {
            target_mode(\*P2A, \*P1B, $trgpath);
            exit 0;
        }
    }
}

