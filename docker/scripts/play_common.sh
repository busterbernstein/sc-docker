#!/usr/bin/env bash


function LOG() {
    echo `date +%Y-%m-%dT%H:%M:%S` "$@"
}

# From https://stackoverflow.com/a/24413646
#
# Usage: run_with_timeout N cmd args...
#    or: run_with_timeout cmd args...
# In the second case, cmd cannot be a number and the timeout will be 10 seconds.
#
# Exit code 143 means it exited with timeout
function run_with_timeout () {
    local time=10
    if [[ $1 =~ ^[0-9]+$ ]]; then time=$1; shift; fi
    # Run in a subshell to avoid job control messages
    ( "$@" &
      child=$!
      # Avoid default notification in non-interactive shell for SIGTERM
      trap -- "" SIGTERM
      ( sleep $time
        kill $child 2> /dev/null ) &
      wait $child
    )
}

function fully_qualified_race_name() {
    SHORT="$1"
    if [ "$SHORT" == "T" ]; then
        echo "Terran"
    elif [ "$SHORT" == "P" ]; then
        echo "Protoss"
    elif [ "$SHORT" == "Z" ]; then
        echo "Zerg"
    elif [ "$SHORT" == "R" ]; then
        echo "Random"
    fi
}

function prepare_bwapi() {
    PLAYER_DLL="$1"

    LOG "Preparing bwapi.ini"
    BWAPI_INI="$BWAPI_DATA_DIR/bwapi.ini"

    MAP=$(echo $MAP_NAME | sed "s:$MAP_DIR:maps:g")
    RACE=$(fully_qualified_race_name ${PLAYER_RACE})

    sed -i "s:^ai = NULL:ai = $PLAYER_DLL:g" "${BWAPI_INI}"
    sed -i "s:^character_name = :character_name = $PLAYER_NAME:g" "${BWAPI_INI}"
    sed -i "s:^race = :race = $RACE:g" "${BWAPI_INI}"
    sed -i "s:^game_type = :game_type = $GAME_TYPE:g" "${BWAPI_INI}"
    sed -i "s:^save_replay = :save_replay = $REPLAY_FILE:g" "${BWAPI_INI}"
    sed -i "s:^wait_for_min_players = :wait_for_min_players = $NUM_PLAYERS:g" "${BWAPI_INI}"
    sed -i "s:^speed_override = :speed_override = $SPEED_OVERRIDE:g" "${BWAPI_INI}"

    # todo: solve bug with "Unable to distribute map"
    # hotfix for headful mode, but we need to select map unfortunately
    # it works for headless mode
    if [ "$IS_HEADFUL" == "1" ]; then
        sed -i "s:^game = :game = JOIN_FIRST:g" "${BWAPI_INI}"
    else
        if [ $NTH_PLAYER == "0" ]; then # if is_server
            sed -i "s:map = :map = $MAP:g" "${BWAPI_INI}"
        fi
        sed -i "s:^game = :game = ${GAME_NAME}:g" "${BWAPI_INI}"
    fi

    . hook_update_bwapi_ini.sh

    cat "$BWAPI_INI"
}

function start_gui() {
    if [ -z "${LOG_GUI+set}" ]; then
        LOG_XVFB="/dev/null"
        LOG_XVNC="/dev/null"
    else
        LOG_XVFB="${LOG_DIR}/${LOG_BASENAME}_xvfb.log"
        LOG_XVNC="${LOG_DIR}/${LOG_BASENAME}_xvnc.log"
    fi


    # Launch the GUI!
    LOG "Starting X, savings logs to " "$LOG_XVFB"
    Xvfb :0 -auth ~/.Xauthority -screen 0 640x480x24 >> "$LOG_XVFB" 2>&1 &
    sleep 1

    LOG "Starting VNC server" "$LOG_XVNC"
    x11vnc -forever -nopw -display :0 >> "$LOG_XVNC" 2>&1 &
    sleep 1
}

function start_bot() {
    . hook_before_bot_start.sh

    # Launch the bot!
    LOG "Starting bot ${BOT_FILE}" >> "$LOG_BOT"
    echo "------------------------------------------" >> "$LOG_BOT"
    {
        pushd $SC_DIR

        # todo: run under "bot"
        if [ "$BOT_TYPE" == "jar" ]; then
            win_java32 \
                -jar "${BOT_EXECUTABLE}" \
                >> "${LOG_DIR}/${LOG_BASENAME}_bot.log" 2>&1
            LOG "Bot exited." >> "$LOG_BOT"

        elif [ "$BOT_TYPE" == "exe" ]; then
            wine "${BOT_EXECUTABLE}" \
                >> "${LOG_DIR}/${LOG_BASENAME}_bot.log" 2>&1
            LOG "Bot exited." >> "$LOG_BOT"

        fi

        popd
    } &

    . hook_after_bot_start.sh

}

function start_game() {
    . hook_before_game_start.sh

    [ -f "$MAP_DIR/replays/LastReplay.rep" ] && rm "$MAP_DIR/replays/LastReplay.rep"

    # Launch the game!
    LOG "Starting game" >> "$LOG_GAME"
    echo "------------------------------------------" >> "$LOG_GAME"

    launch_game "$@" >> "$LOG_GAME" 2>&1  &

    . hook_after_game_start.sh
}

function prepare_character() {
    mv "$SC_DIR/characters/default.spc" "$SC_DIR/characters/${PLAYER_NAME}.spc"
    mv "$SC_DIR/characters/default.mpc" "$SC_DIR/characters/${PLAYER_NAME}.mpc"
}

function prepare_tm() {
    cp ${TM_DIR}/${BOT_BWAPI}.dll $SC_DIR/tm.dll
}

function check_bot_requirements() {
    # Make sure the bot file exists
    if [ ! -d "$BOT_DIR/$BOT_NAME" ]; then
        LOG "Bot not found in '$BOT_DIR/$BOT_NAME'"
        exit 1
    fi

    # Make sure the bot file exists
    if [ ! -f "$BOT_DIR/$BOT_NAME/AI/$BOT_FILE" ]; then
        LOG "Bot not found in '$BOT_DIR/$BOT_NAME/AI/$BOT_FILE'"
        exit 1
    fi

    # Make sure the BWAPI file exists
    if [ ! -f "$BOT_DIR/$BOT_NAME/BWAPI.dll" ]; then
        LOG "Bot not found in '$BOT_DIR/$BOT_NAME/BWAPI.dll'"
        exit 1
    fi

    # Make sure that bot type is recognized
    if [ "$BOT_TYPE" != "jar" ] && [ "$BOT_TYPE" != "exe" ] && [ "$BOT_TYPE" != "dll" ]; then
        LOG "Bot type can be only one of 'jar', 'exe', 'dll' but the type supplied is '$BOT_TYPE'"
        exit 1
    fi
}

function detect_game_finished() {
    while true
    do
        LOG "Checking game status ..." >> "$LOG_GAME"

        if ! pgrep -x "StarCraft.exe" > /dev/null
        then
            LOG "Game exited!" >> "$LOG_GAME"
            sleep 3
            return 0
        fi

        if [ -f "$SC_DIR/$REPLAY_FILE" ] || [ -f "$MAP_DIR/replays/LastReplay.rep" ] ;
        then
            LOG "Replays found." >> "$LOG_GAME"
            sleep 3
            return 0
        fi

        sleep 3
    done;
}
